# SauceWG — integration guide for a central API

Everything a central control plane needs in order to drive one or more SauceWG entry
nodes: how the pieces fit together, the complete HTTP surface, the semantics behind
each field, and the invariants you must not break.

Drop this file into the production repository that owns the central API.

---

## 1. What you are integrating with

```
          ┌── client (AmneziaWG profile, generation set per node)
          │
          ▼   UDP, obfuscated
   ┌──────────────────────┐        ┌──────────────┐
   │  ENTRY NODE (RU)     │  awg1  │ EXIT eu-nl   │──► internet
   │                      │────────┤              │
   │  awg0  clients       │  awg2  ├──────────────┤
   │  panel (FastAPI)     │────────┤ EXIT eu-de   │──► internet
   │  postgres            │  awgN  ├──────────────┤
   │  caddy               │────────┤ EXIT …       │──► internet
   └──────────────────────┘        └──────────────┘
            ▲
            │ HTTPS + bearer token
       your central API
```

* **Entry node** — the server users dial. It terminates client tunnels on `awg0` and
  re-tunnels their traffic to one exit node. It runs the panel you talk to.
* **Exit nodes** — plain AmneziaWG servers that NAT the cascade to the internet. They
  have no panel and no API; the entry node is their only client.
* Only **one exit node carries traffic at a time**. The others stay connected and idle
  so a failover is a route swap, not a tunnel rebuild.

**One panel governs one entry node.** If you run several entry nodes, you talk to
several panels; there is no cross-node aggregation inside SauceWG. Model that in the
central API as a list of *(base_url, credentials)* pairs and fan out.

Clients live in the entry node's PostgreSQL. There is no shared user table between
entry nodes — a user who must reach two entry nodes needs a client record on each.

---

## 2. Authentication

```http
POST /api/admin/token
Content-Type: application/x-www-form-urlencoded

username=admin&password=…
```

```json
{ "access_token": "eyJhbGci…", "token_type": "bearer", "expires_in": 86400 }
```

Send it on every other call as `Authorization: Bearer <access_token>`.

| Fact | Value |
| --- | --- |
| Algorithm | HS256, signed with `JWT_SECRET` |
| Lifetime | `JWT_ACCESS_TOKEN_EXPIRE_MINUTES`, default 1440 (24 h) |
| Refresh | none — request a new token |
| Revocation | changing an admin's password bumps its `token_epoch` and invalidates every token issued earlier |

`GET /api/admin` returns the admin the current token belongs to; use it as a cheap
credential health check.

Create a **dedicated non-sudo admin per integration** rather than reusing the human
operator's account, so you can revoke it independently:

```http
POST /api/admins        # requires a sudo token
{ "username": "central-api", "password": "…", "is_sudo": false, "is_active": true }
```

Non-sudo admins can do everything in this document except manage other admins.

Cache the token and re-authenticate on `401`. Do not fetch a token per request.

---

## 3. Users (clients)

A *client* is one AmneziaWG peer: a key pair, an address inside the entry subnet, a
quota and an expiry. **`name` is the identifier used in URLs** — it is unique, and
renaming a client changes its URL. If your central system has its own user IDs, use
them as the `name` (for example `u-48213`) so you never need a mapping table.

`name` must match `^[\w.@ -]+$` and be at most 128 characters.

### 3.1 Create

```http
POST /api/clients
```

```json
{
  "name": "u-48213",
  "data_limit": 107374182400,
  "reset_strategy": "month",
  "expire_in_days": 30,
  "use_preshared_key": true,
  "note": "plan:pro tenant:acme"
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `name` | required | unique identifier, also the URL key |
| `address` | auto | address in the entry subnet; leave unset to let the panel allocate the lowest free one |
| `private_key` / `public_key` | auto | supply your own keys to keep them out of the panel. **If you send only `public_key` the panel cannot render a config** (it has no private key) and `/config` returns `409` |
| `use_preshared_key` | `true` | adds a per-client PSK on top of the handshake |
| `data_limit` | `0` | **bytes**; `0` means unlimited |
| `reset_strategy` | `no_reset` | `no_reset` \| `day` \| `week` \| `month` — rolling quota window |
| `expire_at` | `null` | absolute ISO-8601 UTC |
| `expire_in_days` | — | convenience; ignored when `expire_at` is set |
| `enabled` | `true` | `false` creates the client suspended |
| `note` | `null` | free text — a good place for your own metadata |

Returns `201` with the client object. `409` if the name or public key is taken.

The peer is programmed onto the device **synchronously** inside this request, so the
user can connect as soon as you get the `201`.

### 3.2 Read

```http
GET /api/clients?search=&status=&online=&offset=0&limit=50&sort=created_at&order=desc
GET /api/clients/{name}
```

`limit` is capped at 500. `sort` accepts `name`, `created_at`, `used_total`,
`expire_at`, `last_handshake_at`, `status`. `search` matches name, note and address.

The list response is `{ "total": <int>, "items": [ … ] }` — `total` ignores paging, so
page with `offset` until you have `total` items.

Client object:

```json
{
  "id": 12,
  "name": "u-48213",
  "address": "10.8.0.7",
  "public_key": "P0nD…=",
  "status": "active",
  "enabled": true,
  "data_limit": 107374182400,
  "reset_strategy": "month",
  "used_up": 4812934,
  "used_down": 88213441,
  "used_total": 93026375,
  "lifetime_up": 91223411,
  "lifetime_down": 812334410,
  "expire_at": "2026-09-13T10:00:00Z",
  "last_handshake_at": "2026-08-14T14:22:51Z",
  "last_endpoint": "203.0.113.44:51231",
  "online_at": "2026-08-14T14:22:51Z",
  "is_online": true,
  "sub_token": "9f2c…",
  "note": "plan:pro tenant:acme",
  "created_at": "2026-08-14T09:03:12Z",
  "subscription_url": "http://5.8.30.247/sub/9f2c…"
}
```

Note that the private key is **never** returned. Configs come from the endpoints in
§4.

### 3.3 Update, suspend, delete

```http
PUT    /api/clients/{name}      # name, data_limit, reset_strategy, expire_at, enabled, note
POST   /api/clients/{name}/disable
POST   /api/clients/{name}/enable
POST   /api/clients/{name}/reset               # zeroes used_up/used_down, keeps lifetime_*
POST   /api/clients/{name}/revoke-subscription # new sub_token, old links stop working
DELETE /api/clients/{name}                     # 204, no body
```

`PUT` is a partial update: omitted fields are left alone. All of these reprogram the
device before returning, so the effect is immediate rather than eventual.

### 3.4 Status is derived, never set

`status` is recomputed from the other fields on every write and on every collector
tick. You cannot assign it.

| Status | Condition | Peer on the device |
| --- | --- | --- |
| `disabled` | `enabled == false` | removed |
| `expired` | `expire_at <= now` | removed |
| `limited` | `data_limit > 0` and `used_total >= data_limit` | removed |
| `active` | none of the above | present |

**Only `active` clients exist on the AmneziaWG device.** Suspension is enforced at the
cryptographic layer: a non-active client's handshake is refused outright.

To suspend, set `enabled: false` (or `POST /disable`). To resume, set it back — do not
delete and recreate, or the user's keys and config change.

---

## 4. Delivering a profile to the end user

Three equivalent ways, all rendering the same AmneziaWG `.conf`:

| Endpoint | Auth | Returns |
| --- | --- | --- |
| `GET /api/clients/{name}/config` | bearer | `text/plain` config |
| `GET /api/clients/{name}/qr` | bearer | `image/png` QR of the config |
| `GET /sub/{sub_token}` | the token itself | `text/plain` config, `Content-Disposition` + `Profile-Title` headers |
| `GET /sub/{sub_token}/qr` | the token itself | `image/png` |

The `/sub/…` links carry no admin credentials, so they are what you hand to the end
user (email, deep link, in-app QR). `subscription_url` on the client object is the
ready-made link. A disabled client's subscription returns `403`; rotate the link with
`POST /api/clients/{name}/revoke-subscription`.

Set `SUBSCRIPTION_URL_PREFIX` on the panel to the public base URL if the entry node
sits behind your own domain or gateway, otherwise the link is built from the request
host.

Which parameters the profile contains is decided by the entry interface, not by the
client: the config carries the server's `S1`–`S4` and `H1`–`H4` verbatim, because those
are what each side decodes the other's packets with and a mismatch is a tunnel that never
handshakes. The sender-side parameters are the panel's to choose — `Jc/Jmin/Jmax` from
`CLIENT_JC/JMIN/JMAX`, and the `I1` signature packet from `CLIENT_SIGNATURE` — so clients
can wear a different disguise from the server's own.

The presence of those parameters *is* the AmneziaWG generation, so a profile from a 2.0
entry node (with `S3`, `S4` and `I1`) needs a client that understands them: AmneziaVPN
4.8.2 or newer, or a router on KeeneticOS 5.1 Alpha 3 or newer. `GET /api/settings`
reports which generation the node is on before you hand a profile out; if the users you
serve are on older routers, put the entry node on `1.0`
([`SAUCEWG_USAGE.md` §2.2](SAUCEWG_USAGE.md#22-install-options)).

`GET /api/clients/{name}/config` returns `503` while the node container is still starting
and `409` for a client created with an external public key only.

---

## 5. Traffic and online state

### How the numbers are produced

A collector polls the device every `COLLECTOR_INTERVAL_SECONDS` (default 10 s), reads
per-peer byte counters, and stores the delta. Consequences worth designing around:

* Counters lag reality by up to one interval. They are **not** transactional.
* `used_up` / `used_down` are the quota counters and reset on `POST /reset` or on the
  `reset_strategy` rollover. `lifetime_up` / `lifetime_down` never reset — use those
  for billing.
* `up` is client→internet, `down` is internet→client.
* A client is `is_online` when its last handshake is newer than
  `ONLINE_TIMEOUT_SECONDS` (default 180 s). With a 25 s keepalive that means a
  disconnect shows up within ~3 minutes; it is a liveness signal, not a session log.
* Restarting the node container resets the device counters; the collector detects the
  drop and does not double count.

### Time series

```http
GET /api/clients/{name}/usage?hours=24     # one client
GET /api/system/usage?hours=24             # whole entry node
```

```json
{ "total_up": 8123441, "total_down": 91223411,
  "points": [ { "bucket": "2026-08-14T13:00:00Z", "up": 812344, "down": 9122341 } ] }
```

Buckets are `USAGE_BUCKET_MINUTES` wide (default 60) and retained for
`USAGE_RETENTION_DAYS` (default 90). `hours` accepts 1…2160.

### Recommended polling

| What | How often |
| --- | --- |
| `GET /api/clients?limit=500` for counters and online state | 30–60 s |
| `GET /api/system` for node health | 30 s |
| `GET /api/nodes` for failover state | 10–30 s |
| usage series for reporting | hourly |

There is no webhook or push channel. If you enforce quotas centrally, poll
`lifetime_*`, decide in your own system, and push the decision back with `PUT` or
`/disable` — do not rely on the panel's `data_limit` alone unless the panel is your
source of truth.

---

## 6. Exit nodes and failover

### Reading the topology

```http
GET /api/nodes
```

```json
{
  "mode": "auto",
  "active": "eu-primary",
  "pinned": null,
  "killswitch": false,
  "fallback": "direct",
  "fallback_active": false,
  "stale": false,
  "updated_at": "2026-08-14T14:31:02Z",
  "config_error": null,
  "provisioning": true,
  "bridge": {
    "subnet": "10.77.0.0/24",
    "subnet6": null,
    "family": "auto",
    "probe_target": "1.1.1.1",
    "probe_target6": "2606:4700:4700::1111"
  },
  "nodes": [
    {
      "name": "eu-primary",
      "iface": "awg1",
      "address": "10.77.0.2/32",
      "address6": null,
      "priority": 10,
      "endpoint": "72.56.92.184:51820",
      "endpoint4": "72.56.92.184:51820",
      "endpoint6": null,
      "endpoint_family": 4,
      "family": null,
      "exit_ip": "72.56.92.184",
      "healthy6": false,
      "latency6_ms": null,
      "public_key": "Lkug…=",
      "peer_public_key": "ASPc…=",
      "paired": true,
      "healthy": true,
      "active": true,
      "stalled": false,
      "last_handshake_at": "2026-08-14T14:30:58Z",
      "handshake_age_seconds": 4.2,
      "latency_ms": 47.08,
      "rx_bytes": 3092,
      "tx_bytes": 87289,
      "managed": true,
      "ssh_host": "72.56.92.184",
      "ssh_port": 22,
      "ssh_user": "root",
      "ssh_key": true,
      "created_at": "2026-06-02T09:12:44Z",
      "task_id": null,
      "recovery": null
    },
    { "name": "eu-backup", "priority": 20, "healthy": true, "active": false, "…": "…" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `priority` | **lower wins.** The healthy node with the smallest number carries traffic |
| `healthy` | passed the last health checks (see below), **and** handshaked recently enough for that verdict to still mean something |
| `active` | currently carrying client traffic |
| `stalled` | **check this.** The cascade is still treating this node as usable — offering it as a failover target, or routing clients through it — while its last handshake is too old for anything to be coming out of it. `healthy` is forced to `false` alongside, and `active` may well be `true`: that combination is an exit node carrying nothing |
| `last_handshake_at` / `handshake_age_seconds` | when the tunnel to this node last handshaked, and how long ago in seconds. `null` if it never has |
| `paired` | the exit node's key is installed here; an unpaired node can never become active |
| `public_key` | the **entry node's** key for this uplink — this is what you install on the exit node |
| `peer_public_key` | the exit node's key |
| `latency_ms` | round trip through the tunnel to `CASCADE_PROBE_TARGET` |
| `endpoint` | the address the tunnel to this node is **actually** open on, whichever family that is |
| `endpoint4` / `endpoint6` | both addresses this node is known at. One of them equals `endpoint`; the other is what the container moves to if this one stops answering |
| `endpoint_family` | `4` or `6` — which of the two `endpoint` is. `null` from a node container older than this field, which means 4 |
| `family` | what the *list* asked for: `"4"` or `"6"` pins this node to one endpoint, `null` lets the cascade decide |
| `address6` | this uplink's address on the IPv6 half of the bridge. `null` when the cascade has no IPv6 half, or `"none"` in the list when this node sits it out |
| `healthy6` | the exit node reaches the IPv6 internet through the bridge. **Reported, not acted on** — see [§6 IPv6](#ipv6-through-the-cascade) |
| `latency6_ms` | round trip to `CASCADE_PROBE_TARGET6`, or `null` |
| `bridge` | the link between the entry node and its exit nodes, not the endpoints it is dialled over. `subnet6: null` is an IPv4-only cascade, which is the default |
| `fallback` | what happens if every uplink dies: `direct` carries client traffic through the entry node, `block` drops it |
| `fallback_active` | **check this too.** `true` means that is happening now: with `direct`, users are online but leaving from the entry node's address; with `block`, they are cut off |
| `killswitch` | the same thing for clients written before there were two modes; exactly `fallback == "block"` |
| `stale` | **check this.** `true` means the node container stopped publishing state, so every health field below is untrustworthy |
| `config_error` | a complete sentence explaining why the cascade is not what this panel thinks it is — a list the node container refused, or a `CASCADE_NODES_JSON` overriding the file. `null` when all is well |
| `provisioning` | `false` when this panel cannot edit the cascade, so the write calls below are refused — `403` when provisioning is switched off, `409` when `CASCADE_NODES_JSON` owns the list |
| `managed` | the panel installed this node over SSH and can reach it again |
| `ssh_host` / `ssh_port` / `ssh_user` | how it reaches it; `null` for a node added by hand |
| `ssh_key` | the panel's own key is on that server, so calls about it need no credentials |
| `task_id` | set while an install, removal or repair for this node is still running |
| `recovery` | what the panel's own recovery has tried on this node, or `null` while it is healthy and has nothing to report |

### How failover decides

Each uplink is checked every `CASCADE_PROBE_INTERVAL` (10 s):

1. Unpaired, or no handshake, or last handshake older than
   `CASCADE_HANDSHAKE_TIMEOUT` (180 s) → failed.
2. Otherwise an ICMP probe is sent through that interface to `CASCADE_PROBE_TARGET`
   (`1.1.1.1`). This is what catches an exit node that is still up but has lost its
   own internet.

`CASCADE_FAIL_THRESHOLD` consecutive failures (3) mark it down;
`CASCADE_RECOVER_THRESHOLD` consecutive successes (2) bring it back. With the defaults
an outage is noticed in **about 30 seconds**, and recovery in about 20.

On a switch the container rewrites one route and drops stale NAT conntrack entries so
existing flows re-establish instead of black-holing. Users keep their tunnel to the
entry node throughout — they see a new exit IP and broken TCP sessions, not a
disconnect.

### A verdict is never older than the handshake it was made on

Everything above is decided by a loop, and a loop can stop: wedged on a system call,
killed while the container carries on running, or simply not having reached its first
tick yet. Its last verdict then stays in `uplinks.json` — `healthy: true`, `active:
true` — beside a `last_handshake` that keeps getting older, and nothing downstream can
tell that from a working exit node. This is how a node with a six-hour-old handshake
gets reported as connected.

So a health flag is only published, and only believed, while the handshake beside it
could still belong to a live tunnel:

```
dead_after = CASCADE_HANDSHAKE_TIMEOUT + failover_seconds   # 180 + 30 by default
```

`failover_seconds` is `CASCADE_PROBE_INTERVAL × CASCADE_FAIL_THRESHOLD`: the hysteresis
keeps a node healthy through three bad probes on purpose, so a handshake is allowed to
be that much older than the timeout while the verdict is still legitimately "healthy".
Past that sum, it is not.

Both numbers are published in `uplinks.json` so that everything reading it applies the
container's own rule rather than guessing at one. The panel falls back to `180` and `30`
for a node container that predates them.

The rule is enforced three times over, because each layer can be the stale one:

* the node container will not **publish** `healthy: true` for a node whose
  `last_handshake` is already past `dead_after` — a monitor that has stopped evaluating
  health cannot leave a healthy verdict standing behind it;
* the panel **re-checks** it on every read, against the timestamp in the same snapshot,
  and downgrades `healthy` to `false` and raises `stalled` when the two disagree;
* `saucewg nodes` does the same against the file, so the CLI does not disagree with the
  panel about a node either.

`stalled` is the name for the disagreement: not merely down, but down while the cascade
still counts on it. It is worth alerting on separately, because failover cannot fix a
failure it has not noticed:

```python
for node in get("/api/nodes")["nodes"]:
    if node["stalled"] and node["active"]:
        alert(f"{node['name']} is carrying client traffic and has stopped handshaking")
```

### When there is nothing to fail over to

If no uplink passes its checks, `CASCADE_FALLBACK` on the entry node decides what users
experience:

| Value | Effect | `GET /api/nodes` |
| --- | --- | --- |
| `direct` (default) | the entry node carries client traffic itself | `active: null`, `fallback_active: true` |
| `block` | client traffic is dropped | `active: null`, `fallback_active: true` |

Either way `active` is `null` and `cascade.connected` in `GET /api/system` is `false`:
those describe the cascade, which is down in both cases. `fallback` tells the two apart,
and it matters to a central API for a reason worth stating plainly — under `direct`,
users are **online, from the entry node's address**, which for an entry node in a
censored country is exactly the exposure the cascade exists to avoid. It is temporary
and reverts on its own the moment an uplink recovers, but a status page that reports
"connected" without saying which address the traffic is leaving from is lying by
omission.

An alert worth having:

```python
state = get("/api/nodes")
if state["fallback_active"] and not state["stale"]:
    if state["fallback"] == "direct":
        alert("every exit node is down; users are leaving via the entry node's IP")
    else:
        alert("every exit node is down; users are cut off")
```

`killswitch` is still published and is exactly `fallback == "block"`, so an integration
written before this existed keeps working. A node container older than the panel
publishes only `killswitch`, and the panel reports `fallback` accordingly.

The mode is set on the entry node, not through the API — `saucewg fallback direct|block`,
or `CASCADE_FALLBACK` in `.env` — because it is a property of that node's deployment
rather than something to toggle per request.

### Putting a failed node back

Failover is not repair, and this distinction is the one most likely to be missed by a
status page: a failed exit node stays failed. Users are fine, the cascade has one fewer
node, and nothing says so unless something asks. The panel therefore tries to recover
it — it is the only component that can, since it holds an SSH key on every node it
installed — and reports what happened per node:

```json
"recovery": {
  "attempts": 2,
  "last_action": "restart",
  "last_error": "the server is up and the uplink key was re-installed, but the tunnel still does not handshake",
  "blocked": null,
  "down_for_seconds": 512,
  "since_last_attempt_seconds": 47,
  "recovered": false
}
```

| Field | Meaning |
| --- | --- |
| `attempts` | how many recovery runs this outage has had. Reset when the node comes back |
| `last_action` | how far the last one escalated: `probe` (opened an SSH session), `restart` (restarted the service), `repair` (re-installed the uplink key) |
| `last_error` | why it did not work, as a sentence fit to show an operator |
| `blocked` | **the field to alert on.** `unreachable` means the server does not answer SSH at all — a deleted or suspended VPS, and nothing further will be tried. `exhausted` means the attempt budget is spent. `null` means it is still working on it |
| `down_for_seconds` | how long the uplink has been unhealthy |
| `since_last_attempt_seconds` | age of the last attempt; `null` before the first |
| `recovered` | `true` when an attempt brought it back — the object is dropped on the next sweep |

Attempts start after `NODE_RECOVERY_GRACE_SECONDS` (5 min), so a reload or a reboot is
not chased, and back off geometrically after that. One node is worked on at a time, and
never one an operator is already acting on (`task_id` set).

This history lives in the panel process, so restarting the panel — which `saucewg update`
does — clears it: `attempts` and `down_for_seconds` return to zero, and a node that had
been given up on as `unreachable` is tried again from the start. That is deliberate, since
a restart is usually the operator having changed something. It does mean the whole
`recovery` object describes the current panel's effort, not the outage: for how long a
node has really been down, use `last_handshake_at`, which the node container reports and
a panel restart does not touch.

```http
POST /api/nodes/{name}/recover
```

Runs the same escalation now, and returns `202` with a task to poll like every other
node operation. It takes no body: it uses the panel's key, which is what makes it usable
from a bot. The task **succeeds even when the node does not come back** — the attempt ran
and reported what it found, which is the answer that was asked for — so read
`task.result`:

```json
{ "name": "pl-129", "healthy": false, "acted": true,
  "blocked": "unreachable", "attempts": 3, "last_action": "probe",
  "last_error": "72.56.246.208 did not answer in time", "…": "…" }
```

| `result` field | Use |
| --- | --- |
| `healthy` | `true` when the uplink is carrying traffic again. This is the success condition |
| `acted` | `false` when the node was already healthy and nothing was touched |
| the rest | the same fields as `recovery` above |

`422` if the node was added by hand and has no SSH address, or if the panel has no key
on it: those are recoverable only on that server, with `saucewg restart`. `404` for an
unknown name, `409` while another operation on it is running.

Asking for it also clears a `blocked` verdict, because an operator asking has usually
just fixed the reason for it. Worth knowing for a bot that offers a "try again" button
after telling a user their node is unreachable.

An alert worth having, alongside the fallback one above:

```python
for node in get("/api/nodes")["nodes"]:
    r = node.get("recovery") or {}
    if r.get("blocked") == "unreachable":
        alert(f"{node['name']} does not answer SSH; check the VPS still exists")
    elif r.get("blocked") == "exhausted":
        alert(f"{node['name']} could not be restarted: {r['last_error']}")
```

Set `NODE_RECOVERY_ENABLED=false` on the entry node to switch the automatic part off
while leaving the endpoint available.

### Steering it

```http
POST /api/nodes/{name}/activate    # prefer this exit node
POST /api/nodes/auto               # drop the preference
```

Both return the same object as `GET /api/nodes`, with `mode` and `pinned` reflecting
what you just asked for. `404` if the name is not configured.

Two things to internalise:

* **A pin is a preference, not a lock.** If the pinned node goes down the container
  still fails over to the next healthy one, and returns to the pin when it recovers.
  There is no way to force traffic onto a dead node.
* **The change is asynchronous.** The container applies it on its next health tick, so
  up to `CASCADE_PROBE_INTERVAL` seconds later. Poll `GET /api/nodes` until `active`
  matches before reporting success to a user.

### Adding and managing an exit node

```http
GET    /api/nodes/ssh-key         # the panel's key, to preload onto a new server
POST   /api/nodes/check           # is this server reachable, and what is on it
POST   /api/nodes                 # install one on a bare server over SSH
POST   /api/nodes/adopt           # register one that was installed by hand
DELETE /api/nodes/{name}          # detach it, optionally wiping the server
POST   /api/nodes/{name}/repair   # reinstall the uplink key on an unpaired node
POST   /api/nodes/{name}/recover  # restart a failed node, then re-pair it if needed
GET    /api/nodes/{name}/status   # containers, version and host facts, live
GET    /api/nodes/{name}/logs     # the tail of that server's container logs
POST   /api/nodes/{name}/restart  # also /start, /stop and /upgrade
```

Installing takes minutes, so `POST` and `DELETE` answer `202` with a task to poll
rather than holding the request open. A node the panel installed carries the panel's
SSH key, so every call after the first needs no credentials — which is what makes
running a fleet from one master panel practical. The full contract — request bodies,
task polling, error codes and the equivalent CLI — is in
[`SAUCEWG_USAGE.md` §5](SAUCEWG_USAGE.md#5-driving-it-from-a-bot).

From a shell on the entry node, the same thing is:

```bash
saucewg add-node --json '{"name":"eu-fr","endpoint":"…","public_key":"…"}'
saucewg remove-node eu-fr
saucewg nodes
```

Adding or removing a node **does not restart anything**. The node container re-reads
the list within a second and rebuilds only the interfaces that actually changed, so
connected users are unaffected unless the node carrying their traffic is the one being
removed.

Writing `config/exit-nodes.json` on the entry host directly still works if you prefer
to own it from configuration management — set `NODE_PROVISION_ENABLED=false` to stop
the panel writing to it too. The file is a JSON array; each object accepts:

```json
{
  "name": "eu-fr",              // unique, stable — keys are stored per name
  "endpoint": "203.0.113.9:51820",
  "public_key": "…=",           // the exit node's public key
  "preshared_key": "…=",        // optional
  "address": "10.77.0.4/32",    // must be inside the exit node's AWG_SUBNET
  "endpoint6": "[2001:db8::9]:51820",  // optional; bracketed
  "family": "6",                // optional; pins which endpoint is dialled
  "address6": "fd00:77::4/128", // optional; inside the exit node's AWG_SUBNET6
  "priority": 30,               // lower wins
  "mtu": 1380,
  "keepalive": 25,
  "s1": 96, "s2": 40,           // must match the exit node exactly
  "h1": 1, "h2": 2, "h3": 3, "h4": 4,
  "jc": 5, "jmin": 50, "jmax": 1000
}
```

Alternatively pass the same array inline as the `CASCADE_NODES_JSON` environment
variable, which takes precedence over the file.

**Invariants that will bite you:**

* `s1`, `s2` and `h1`–`h4` must be identical on both ends of each uplink, and each
  uplink should use a different set from the others.
* Each uplink's `address` must fall inside that exit node's `AWG_SUBNET`, because the
  exit node's NAT rule is scoped to that subnet. The default `10.77.0.0/24` on every
  exit node plus `.2`, `.3`, `.4` … on the entry node satisfies this.
* Set the exit node's `AWG_PEER_ALLOWED_IPS` to the whole uplink subnet
  (`10.77.0.0/24`) so it works in any slot.
* Names are the identity for key storage. Renaming a node in the list generates a new
  key pair and breaks its pairing until you reinstall the key.

### Exit nodes over IPv6

An exit node can be given two endpoints, and one of them can be the only one it has:

```http
POST /api/nodes/adopt
{
  "name": "eu-fr",
  "endpoint": "203.0.113.9:51820",
  "endpoint6": "[2001:db8::9]:51820",
  "public_key": "…="
}
```

Either endpoint alone is enough; a body with neither is a `422`. An IPv6 address is
accepted bracketed or bare and is stored bracketed, because `amneziawg-tools` reads
the last `:` group of an unbracketed endpoint as the port. Typing an IPv6 address into
the plain `endpoint` field works too — it is recognised and moved to `endpoint6`
rather than silently written into a config that could never handshake. The same three
fields are accepted by `PUT /api/nodes/{name}`, and `family` by both:

| `family` | Effect |
| --- | --- |
| absent / `"auto"` | the cascade decides, and may move the uplink between the two endpoints |
| `"4"` / `"6"` | pinned: this node is only ever dialled over that family |

**The cascade may move an uplink to its other endpoint.** When a tunnel goes a whole
`CASCADE_FAIL_THRESHOLD` window without a handshake, the address it is being dialled
on is treated as not working from here and the uplink is rebuilt on the other one.
This is why `endpoint` is documented as "the address it is actually open on": read
`endpoint_family` if you need to know which, rather than assuming the first one you
sent. A node with `family` set is never moved, and neither is one with a single
endpoint.

Which is also why an endpoint can be taken away — `{"endpoint6": "none"}` — rather than
only replaced. An address that has stopped working is somewhere the uplink will keep
being rebuilt onto; removing it is how that stops. Removing the last one is a `422`,
since a node with no address is one the cascade can only report as permanently down.

`POST /api/nodes` — the SSH install — takes an IPv6 address as `host`, so an
IPv6-only VPS is provisioned exactly like any other. The panel needs IPv6 of its own
to reach it; without that the task fails at the first SSH connection and says so in
its log.

### IPv6 through the cascade

Separately from how a tunnel is dialled, the bridge inside it can carry IPv6:

```json
"bridge": {
  "subnet": "10.77.0.0/24",
  "subnet6": "fd00:77::/64",
  "family": "auto",
  "probe_target": "1.1.1.1",
  "probe_target6": "2606:4700:4700::1111"
}
```

`subnet6` is `null` on a default installation and on every installation updated into
this version; it is turned on with `CASCADE_UPLINK_SUBNET6` on the entry node and
`AWG_SUBNET6` on each exit node, which must agree. From a shell that is
`saucewg bridge on` and `saucewg install-node --subnet6 … --reinstall`. Each uplink
then gets an `address6` on it and the exit node NATs that prefix out of its own IPv6.

`healthy6` is measured per uplink by sending to `probe_target6` from that uplink's own
bridge address, so every exit node is asked about its own IPv6 rather than only the
active one. That needs a route out of each uplink, which the entry node keeps in a
table of its own that nothing but the bridge's prefix is routed to. IPv4 needs no
equivalent — the kernel lets a device-bound send leave a point-to-point interface with
no route at all, and IPv6 refuses it, which is why a bridge configured correctly at both
ends can still report every node `healthy6: false` on an entry node that has not been
updated to a version with that route.

The reason to care, as an integrator: **`healthy6` is reported and never acted on.**
An exit node whose IPv6 has broken keeps `healthy: true`, stays active and carries
client traffic. Clients are IPv4, so failing them over would cost them a working
tunnel to fix a family none of them use. If you are monitoring a fleet, `healthy6`
false with `healthy` true is a real problem at that node's provider that nothing in
SauceWG will resolve on its own — and it is deliberately not an outage.

Clients are unaffected by any of this. `awg0` has no IPv6 address, profiles carry
`AllowedIPs = 0.0.0.0/0`, and no packet a client sends can reach the IPv6 bridge.
A node container older than this version publishes no `bridge` key at all, which reads
as an IPv4-only cascade rather than an error.

---

## 7. Routing past the cascade

Individual destinations can be taken off the cascade and sent out of the entry node's own
uplink: a service that refuses a foreign address, one that is only fast locally, or one
you would simply rather not carry abroad. Everything not listed still goes to the active
exit node.

```http
GET    /api/routes            # the list, with what is actually in effect
POST   /api/routes            # add one or more prefixes
PUT    /api/routes/{cidr}     # relabel one, or turn it off without losing it
DELETE /api/routes/{cidr}     # put that destination back on the cascade
```

```json
{
  "routes": [
    { "cidr": "142.250.0.0/15", "note": "youtube", "enabled": true, "active": true },
    { "cidr": "8.8.8.8/32", "note": "youtube", "enabled": true, "active": false }
  ],
  "via": "eth0",
  "live": true,
  "editable": true,
  "config_error": null
}
```

| Field | Meaning |
| --- | --- |
| `cidr` | the destination, always masked to its network — `8.8.8.8` is stored as `8.8.8.8/32` |
| `enabled` | `false` keeps the entry in the list without routing it |
| `active` | **the one that matters.** `true` when the node container has it in its routing table; `false` means listed but not in effect |
| `via` | the entry node's own interface these leave through |
| `live` | `false` when the node container is not publishing routing state — stopped, or older than this feature — so every `active` above is unknown rather than false |
| `editable` | `false` when this panel cannot write the list (`NODE_PROVISION_ENABLED=false`) |
| `config_error` | why the list on file is not the list in effect, as a sentence, or `null` |

Adding takes an array, because these arrive in groups — every range a service resolves
to:

```http
POST /api/routes
{ "cidr": ["142.250.0.0/15", "64.233.160.0/19", "8.8.8.8"], "note": "youtube" }
```

Prefixes already listed are skipped rather than rejected, so re-posting a group after it
has grown adds only what is new. The response is the whole list, in the same shape as
`GET`. A `note` is free text and is the handle for removing a group later — the panel and
the CLI both group by it.

The path parameter contains a slash and is taken literally: `DELETE /api/routes/142.250.0.0/15`.
Encoding it as `%2F` works too.

**Rules the API enforces:**

* **IPv4 only.** An IPv6 prefix is a `400`: the cascade routes IPv4, so an IPv6
  destination bypasses it already.
* **No hostnames.** Nothing is resolved. Resolve in your own system and post the
  addresses — which is also the only honest way to do it, since a name that answers with
  a different address tomorrow would silently stop being routed.
* **`0.0.0.0/0` is a `400`.** Taking every destination off the cascade is
  `CASCADE_FALLBACK=direct`, not a route.
* **Host bits are masked, not rejected.** `10.20.30.40/24` is stored as `10.20.30.0/24`,
  because that is what it means and the kernel would refuse the literal form.

Changes reach the node container within a second and disturb no tunnel. `active` is what
to poll if you need to confirm one landed; a prefix that stays `false` with `live: true`
and a `config_error` means the container could not install it — most often because the
entry node has no default route of its own to send it out of.

Writes answer `409` when the list is not the panel's to edit, with the reason in
`detail`: `NODE_PROVISION_ENABLED=false`, or a `CASCADE_DIRECT_ROUTES` environment
variable overriding the file. The equivalent on the entry node itself is
`saucewg routes`, `saucewg add-route` and `saucewg remove-route`.

---

## 8. Destinations the entry node reopens

§7 decides *which way out* a destination takes. This is for destinations where no way
out works: the outbound TCP handshake to their IPv4 is dropped, so nothing connects,
while DNS resolves correctly, ICMP is answered and any flow that did get established
keeps running. A route cannot fix that — the packets leave by a different interface and
are dropped identically — so the entry node opens the outbound half itself, over the
destination's IPv6 where the same service answers there, and by re-dialling its IPv4
until a handshake lands where it does not.

Telegram is the case this exists for; its datacentres ship as a built-in group, so the
common deployment needs no list at all.

```http
GET    /api/bypass            # the list, with what is actually engaged
POST   /api/bypass            # add one or more destinations
PUT    /api/bypass/{cidr}     # change its IPv6 counterpart, relabel it, or turn it off
DELETE /api/bypass/{cidr}     # stop reopening it
```

```json
{
  "entries": [
    { "cidr": "149.154.167.51/32", "v6": "2001:67c:4e8:f002::a", "note": "telegram-dc2",
      "enabled": true, "active": true, "built_in": true },
    { "cidr": "203.0.113.0/24", "v6": null, "note": "some service",
      "enabled": true, "active": true, "built_in": false },
    { "…": "…" }
  ],
  "mode": "auto",
  "groups": ["telegram"],
  "active": true,
  "live": true,
  "editable": true,
  "config_error": null,
  "relay": {
    "listen": "10.8.0.1:8646",
    "prefixes": 26,
    "open": 3,
    "accepted": 412,
    "via_v6": 380,
    "via_retry": 29,
    "failed": 3,
    "attempts": 1174,
    "cooled": 6,
    "rx_bytes": 8419203,
    "tx_bytes": 1204884
  }
}
```

| Field | Meaning |
| --- | --- |
| `cidr` | the destination, masked to its network as in §7 |
| `v6` | where the same service answers over IPv6, or `null` — then its own IPv4 is retried |
| `built_in` | `true` for an entry that comes from a `groups` table rather than the list. It can be turned off but not deleted |
| `enabled` | `false` keeps it listed without reopening it |
| `active` | the node container has a redirect installed for it right now |
| `mode` | `auto`, `always` or `off` — see below |
| `groups` | built-in tables in force, currently only `telegram` |
| `active` (top level) | **the one that matters.** Whether the redirect is installed at all |
| `live` | `false` when the node container is not publishing this, so every `active` is unknown rather than false |
| `relay` | the relay process's own counters, absent when it is not running |
| `config_error` | why the list on file is not what is in force, or `null`. An idle `auto` is **not** an error |

`relay.via_v6` against `relay.via_retry` is the useful pair to graph: it says which of
the two paths is actually carrying the traffic, and `attempts / via_retry` is a direct
measurement of how hard the filter is dropping handshakes — around 12 on a live Moscow
node, meaning about one handshake in twelve is being answered.

`relay.cooled` counts flows for a destination that had already spent a whole budget
without answering, and so were given a short burst instead of a long one. A high and
rising `cooled` is not a fault: it means clients are hammering an address that answers
nothing — a datacentre endpoint blocked outright rather than sampled — and that this is
costing a twelfth of what it otherwise would. It is, though, the number to look at when
`failed` is large: on a live node a single such address accounted for 98% of all failures,
and no amount of retrying was ever going to open it.

The two kinds of block are worth telling apart, because only one of them retrying can
solve. A sampled destination answers a few handshakes in twenty from the blocked network
— retrying finds one of them. An outright-blocked one answers none from there while
answering normally from a network the filter is not on. The measured example was
`91.105.192.100`, a Telegram MTProto endpoint: 0 handshakes in 20 from the entry node's
hosting segment, 10 in 10 from a Russian consumer ISP. So the address is alive and the
filtering sits on the datacentre's uplink, which is also why this is a hosting problem
rather than a national one. Nothing the entry node does alone opens it: it needs a path
the block is not on, which means either an IPv6 counterpart or an exit node. Clients reach
Telegram anyway because every DC it must have is mapped to IPv6, and a client that cannot
reach one endpoint of a DC uses another — which is why `cooled` can be most of `failed` on
a node where Telegram is working perfectly well.

**`mode` and why `active` can be `false` with nothing wrong:**

| `mode` | The redirect is installed |
| --- | --- |
| `auto` (default) | only while client traffic is leaving through the entry node — a cascade outage, or no exit node configured |
| `always` | whenever the node container is running |
| `off` | never |

In `auto` on a healthy cascade, entries read as listed and **not** active. That is
correct: a flow already leaving from another country is not meeting this filter, and
relaying it would add a hop for nothing. A monitoring rule that treats
`active: false` as a fault will fire permanently on a working system — alert on
`config_error`, or on `relay` being absent while `active` is `true`.

Like `mode`, the value is a property of the deployment (`BYPASS_MODE`, or
`saucewg bypass auto|always|off`) rather than something to set per request.

Adding takes an array, as §7 does, but with one difference that matters:

```http
POST /api/bypass
{ "cidr": ["203.0.113.0/24"], "v6": "2001:db8::a", "note": "some service" }
```

* An entry carries *how* to reach the destination, so **re-posting one corrects it**
  rather than being skipped as a duplicate. A direct route is only a destination, so
  §7 skips duplicates; here the second post is how you fix a wrong `v6`.
* `v6` applies to one destination. Posting several `cidr` values with a `v6` is a
  `400` — they would all be relayed to one address.
* IPv4 prefixes only for `cidr` (an IPv6 destination is not being filtered this way),
  a single IPv6 address for `v6`, and `0.0.0.0/0` is refused for the same reason as
  in §7.
* `DELETE` on a `built_in` entry is a `409`, with the reason: the table ships in the
  node image, so the only durable way to switch one off is
  `PUT {"enabled": false}`, which is recorded in the list and survives an update.

Writes answer `409` when the list is not the panel's to edit — `NODE_PROVISION_ENABLED=false`,
or a `BYPASS_ROUTES` environment variable overriding the file. The equivalent on the
entry node is `saucewg bypass`, `saucewg bypass add` and `saucewg bypass remove`.

---

## 9. Blocking BitTorrent

Torrent traffic is the one thing that gets a server taken away rather than throttled: a
swarm sees the address of whichever node carries a client out, and a datacentre answers
the copyright notice by suspending that server rather than by asking who was behind it.
One client seeding for an evening is every client on that node disconnected. So the node
blocks it, on by default, and this is the switch and the report.

```http
GET /api/torrents            # what is blocked here, and what it caught
PUT /api/torrents            # turn it on or off, or change the mode
```

```json
{
  "enabled": true,
  "mode": "on",
  "active": true,
  "active_mode": "on",
  "rules": 61,
  "capabilities": { "string": true, "ipset": true, "connbytes": true, "comment": true },
  "blocked": { "dht": 9100, "utp": 4400, "tracker": 130, "peer": 88, "total": 13630 },
  "peers": 1842,
  "clients": [
    { "address": "10.8.0.14", "name": "andrey-laptop", "client_id": 7,
      "packets": 12800, "expires_in": 84000 }
  ],
  "live": true,
  "editable": true,
  "config_error": null
}
```

| Field | Meaning |
| --- | --- |
| `enabled` | the switch, as configured here |
| `mode` | `on` or `strict`, as configured here. **Kept while `enabled` is false**, so switching off and on again returns to the mode that was chosen |
| `active` | the node container has the rules installed right now |
| `active_mode` | the mode it is actually running, which differs from `mode` for the second or two after a change, and permanently when `TORRENT_BLOCK` overrides the file |
| `rules` | how many iptables rules that took, a useful sanity check on a degraded kernel |
| `capabilities` | which kernel matches this host has — see below |
| `blocked` | packets dropped per layer since the node last started, plus `total`. Read off the rules themselves, so it resets when the container does |
| `peers` | addresses currently blacklisted for having spoken the protocol |
| `clients` | who tripped it, most persistent first, capped at 50 |
| `live` | `false` when the node container is not publishing this — it is stopped, or older than this feature. Everything above it is then unconfirmed |
| `editable` | `false` when the panel is not the one in charge |
| `config_error` | why what is configured is not what is in force, or `null` |

`clients[].name` and `client_id` are filled in by matching the address the container saw
against the client table, so the answer to "who is torrenting" is somebody to talk to
rather than an IP. They are `null` for an address with no current client behind it — a
device on the subnet, or a client deleted since. **Nothing on this list is blocked for
being on it**: it is a reporting window, kept for a day, and a large `packets` is a
torrent client nobody has told to stop, retrying peers it will never reach.

`blocked` is keyed by layer, and which keys appear depends on the mode and the kernel:
`dht`, `tracker`, `lsd`, `dns` (peer discovery), `utp`, `handshake`, `pex`, `peer`,
`port` (the peer wire), `metainfo` (a `.torrent` file on its way back), and
`strict-tcp` / `strict-udp` in strict mode. `total` excludes the pass-through rules, so
it counts what died rather than what was inspected. Treat unknown keys as additive.

**The two modes:**

| `mode` | What it does |
| --- | --- |
| `on` | blocks peer discovery on protocol signatures, matches peer connections by the shape of their opening packet before MSE encrypts anything, and blacklists every address caught speaking either for an hour |
| `strict` | the same, plus outbound TCP and UDP refused except to the ports real services answer on |

`strict` exists as a separate mode because it is the only layer that can inconvenience
somebody who was not torrenting: it closes the one case signatures cannot see — an
encrypted connection to an address the client already knew, on a port nothing else uses
— and in doing so breaks anything on a port nobody named, including a VPN a client runs
inside the tunnel. That last part is deliberate, since such a tunnel would carry
torrents where nothing downstream could see them. Warn the user before offering it.

```http
PUT /api/torrents
{ "enabled": true }        # both fields optional and independent
{ "mode": "strict" }       # changes the dial without touching the switch
```

A `mode` outside `on|strict` is a `422`. Writes answer `409` when the switch is not the
panel's to change: `NODE_PROVISION_ENABLED=false`, or a `TORRENT_BLOCK` environment
variable pinning it. Both are reported in `config_error` on the `GET` as well, so a UI
can disable the control rather than discover it on submit.

**`capabilities` is worth checking once per node.** The filter is built on iptables
match extensions, and a host without them silently gets less than was asked for. The
node probes for each and publishes what it found:

| Key | Missing means |
| --- | --- |
| `string` | **no signature layer at all** — the guard degrades to a port filter, which stops a default client and nothing more. `config_error` says so |
| `ipset` | a caught address is not remembered, so an encrypted reconnection to a known peer is judged on its own and gets through |
| `connbytes` | every packet of a connection is scanned rather than the first 32, which costs throughput but blocks the same |
| `comment` | the per-layer `blocked` counters are unavailable; `total` still works |

A rule the kernel refuses is skipped and counted rather than being fatal, so a partial
kernel still gets whatever it can support.

Changes apply within about a second and disturb no tunnel. Turning the guard on also
drops the conntrack entries for client traffic, so a torrent already running stops
rather than finishing — its handshake is in the past and there would be nothing left to
match. The equivalent on the entry node itself is `saucewg torrents`.

---

## 10. Node information

```http
GET /api/system
```

Host metrics, client totals, live throughput, and the cascade summary:

```json
{
  "panel_title": "SauceWG", "version": "1.4.0",
  "cpu_percent": 3.4, "cpu_cores": 2,
  "mem_total": 2084986880, "mem_used": 903168000,
  "disk_total": 41660260352, "disk_used": 9331159040,
  "uptime_seconds": 194512,
  "clients_total": 42, "clients_active": 39, "clients_online": 11,
  "total_up": 91223411, "total_down": 812334410,
  "incoming_speed": 41231, "outgoing_speed": 812344,
  "node_ready": true,
  "server_public_key": "xstz…=",
  "endpoint": "5.8.30.247:443",
  "cascade": {
    "enabled": true, "connected": true, "iface": "awg1",
    "endpoint": "72.56.92.184:51820", "exit_ip": "72.56.92.184",
    "peer_public_key": "ASPc…=", "last_handshake_at": "2026-08-14T14:23:06Z",
    "rx_bytes": 3092, "tx_bytes": 87289,
    "node": "eu-primary", "stalled": false, "mode": "auto",
    "nodes_total": 2, "nodes_healthy": 2,
    "endpoint_family": 4, "healthy6": false, "nodes_healthy6": 0,
    "bridge_subnet6": null, "bridge_family": "auto",
    "fallback": "direct", "fallback_active": false,
    "direct_routes": 3,
    "bypass_active": false, "bypass_routes": 0
  }
}
```

`cascade.connected` describes the cascade only: it is `false` whenever no exit node is
carrying traffic, including while `fallback_active` is `true` and users are online
through the entry node. `cascade.stalled` is the worst way for it to be `false` — `node`
names an exit node, client traffic is routed to it, and it has stopped handshaking
without failover moving anyone off it. `direct_routes` counts the prefixes of §7 the node container has
actually installed as routes. `bypass_active` and `bypass_routes` are the same for §8 —
both zero on a healthy cascade in the default mode, which is the intended state rather
than a fault.

`endpoint_family` is which family the active uplink is dialled over, `4` or `6`.
`bridge_subnet6` is `null` unless the cascade carries IPv6 to its exit nodes, and
`healthy6`/`nodes_healthy6` are then whether it reaches the IPv6 internet and how many
nodes do. None of the three affects `connected`: an exit node with broken IPv6 is still
carrying clients, who are IPv4 — see [§6](#ipv6-through-the-cascade).

`node_ready` is `false` while the node container is still starting; config rendering
fails with `503` until it flips. `total_up`/`total_down` are lifetime sums across all
clients. `incoming_speed`/`outgoing_speed` are bytes per second from the last
collector delta.

```http
GET /api/settings
```

The entry interface's public parameters — public key, endpoint, subnet, MTU, the
`S1/S2/H1–H4` profile and the client defaults. Useful if you render configs yourself
instead of using `/config`.

```http
POST /api/system/sync
```

Forces peer reconciliation and returns `{"added": n, "updated": n, "removed": n}`.
The panel already reconciles on every write and every `SYNC_INTERVAL_SECONDS`
(default 30), so this is a repair tool, not part of the normal path.

`GET /api/health` needs no auth and returns `{"status":"ok","version":"…"}` — use it
as a liveness probe.

---

## 11. Errors

FastAPI's shape throughout:

```json
{ "detail": "A client with this name already exists" }
```

`422` carries the structured Pydantic list instead of a string, so decode `detail`
defensively.

| Code | When | What to do |
| --- | --- | --- |
| `401` | missing, expired or revoked token | re-authenticate once, then fail |
| `403` | non-sudo token on an admin endpoint, or a disabled subscription | do not retry |
| `404` | unknown client, admin or exit node | do not retry |
| `409` | duplicate name/public key, config for a key-only client, another task still running for that exit node, or a cascade this panel does not own | reconcile your state |
| `422` | validation, or missing SSH credentials for an operation that needs them | fix the payload |
| `503` | node container not ready, or a control file unwritable | retry with backoff |

Everything is served over plain HTTP on the entry node's IP by default. Put it behind
your own TLS termination, or set `PANEL_SITE_ADDRESS` to a domain with
`CADDY_AUTO_HTTPS=on`, before letting a central API reach it across the internet.
Restrict `CORS_ORIGINS` too — it defaults to `*`.

---

## 12. Integration recipes

**Provision a user**

```
POST /api/clients { name: <your user id>, data_limit, expire_in_days }
→ 201, take `subscription_url` from the response and send it to the user
```

No second call is needed; the peer is live when the `201` returns.

**Suspend for non-payment, then restore**

```
POST /api/clients/{id}/disable      → status becomes "disabled", peer removed
POST /api/clients/{id}/enable       → status recomputed, peer restored
```

Keys, address and subscription link survive, so the user's installed profile keeps
working after restoration.

**Change a plan**

```
PUT /api/clients/{id} { "data_limit": 214748364800, "expire_at": "2026-12-31T00:00:00Z" }
```

If the new limit is above current usage, a `limited` client returns to `active` and its
peer is reinstated in the same request.

**Meter for billing**

Poll `GET /api/clients?limit=500` on a schedule and persist `lifetime_up` /
`lifetime_down` per client. They are monotonic (except when a client is deleted), so
your central system can compute deltas without worrying about the panel's own quota
resets.

**Monitor the cascade**

Alert when any of these hold for more than a couple of poll cycles:

* `GET /api/nodes` → `stale == true` — the node container's monitor died.
* any node with `stalled == true` — the cascade is still counting on an exit node that
  has stopped handshaking. With `active == true` beside it, that node is carrying client
  traffic and delivering none of it, and failover is not going to step in for a failure
  it has not noticed. This is the one that used to be invisible.
* `nodes_healthy == 0` — every exit is down. What that means for users depends on
  `fallback`: they are either online from the entry node's own address or offline by
  design, and both deserve an alert.
* `fallback_active == true` while `stale == false` — the same thing, stated by the node
  container itself rather than inferred.
* `active` differs from the lowest-priority healthy node for a sustained period.
* `GET /api/system` → `node_ready == false` after startup.
* `GET /api/routes` → an entry with `enabled: true`, `active: false` and `live: true`
  for more than a poll cycle — a bypass route that is configured but not in force.

**Move users off an exit node for maintenance**

```
POST /api/nodes/{other}/activate    # pin traffic elsewhere
… poll GET /api/nodes until active == {other} …
… do the maintenance …
POST /api/nodes/auto                # hand control back to priority order
```

**Fan out across several entry nodes**

Keep a table of entry nodes with their base URL, credentials and cached token. Use the
same client `name` on each so a user's records line up. Sum `lifetime_*` across nodes
for total usage. Treat each panel as independently failable: a node being unreachable
must not block operations on the others.

---

## 13. Configuration reference

Values the central system may need to know about, set in the entry node's `.env`.

| Variable | Default | Why you care |
| --- | --- | --- |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | — | seeds the first admin on first boot only |
| `JWT_SECRET` | — | rotating it invalidates every token |
| `JWT_ACCESS_TOKEN_EXPIRE_MINUTES` | 1440 | token lifetime |
| `AWG_ENDPOINT_HOST` / `AWG_PORT` | — | what goes into `Endpoint` in client configs |
| `AWG_SUBNET` | `10.8.0.0/24` | caps how many clients fit (254 on a /24) |
| `SUBSCRIPTION_URL_PREFIX` | request host | set when the panel sits behind your gateway |
| `CLIENT_DNS` / `CLIENT_MTU` / `CLIENT_ALLOWED_IPS` | — | defaults baked into every generated config |
| `COLLECTOR_INTERVAL_SECONDS` | 10 | counter freshness |
| `ONLINE_TIMEOUT_SECONDS` | 180 | how long after the last handshake a client still reads as online |
| `USAGE_BUCKET_MINUTES` / `USAGE_RETENTION_DAYS` | 60 / 90 | granularity and history of the usage series |
| `CASCADE_PROBE_INTERVAL` / `CASCADE_FAIL_THRESHOLD` | 10 / 3 | failover detection time; their product is the `failover_seconds` of the staleness rule above |
| `CASCADE_HANDSHAKE_TIMEOUT` | 180 | how old an uplink's last handshake may be before it is dead, whatever else says otherwise |
| `CASCADE_FALLBACK` | `direct` | during a total uplink outage: `direct` carries users through the entry node, `block` cuts them off |
| `CASCADE_KILLSWITCH` | — | the previous name for the same choice; read only when `CASCADE_FALLBACK` is unset, where `true` means `block` |
| `CASCADE_DIRECT_ROUTES` | — | a JSON array of prefixes to route past the cascade, overriding the file and making §7 read-only |
| `CASCADE_UPLINK_SUBNET6` | — | the IPv6 half of the bridge to the exit nodes, e.g. `fd00:77::/64`. Empty is an IPv4-only cascade, and each exit node's `AWG_SUBNET6` must match |
| `CASCADE_ENDPOINT_FAMILY` | `auto` | which family exit nodes are dialled over when they publish both: `auto`, `4` or `6`. A node's own `family` overrides it |
| `CASCADE_PROBE_TARGET6` | `2606:4700:4700::1111` | what `healthy6` is measured against, through the tunnel |
| `BYPASS_MODE` | `auto` | when the reopened destinations of §8 are actually reopened: `auto`, `always`, `off` |
| `BYPASS_GROUPS` | `telegram` | built-in destination tables in force; empty ships none |
| `BYPASS_ROUTES` | — | prefixes to reopen, overriding the file and making §8 read-only |
| `BYPASS_ATTEMPTS` / `BYPASS_PARALLEL` | 96 / 6 | the retry path's handshake budget per connection, and how many of them are outstanding at once |
| `TORRENT_BLOCK` | — | `off`, `on` or `strict` pins the torrent guard of §9 and makes it read-only through the API; empty leaves the switch to the panel |
| `TORRENT_TCP_PORTS` / `TORRENT_UDP_PORTS` | see §9 | the ports `strict` leaves open. Adding 500, 4500 or 51820 lets a client run its own VPN out of the tunnel, and torrent inside that |
| `NODE_PROVISION_ENABLED` | `true` | `false` makes the cascade read-only through the API — see [`SAUCEWG_USAGE.md` §6](SAUCEWG_USAGE.md#6-files-on-the-server) |
| `NODE_RECOVERY_ENABLED` | `true` | whether the panel tries to restart a failed exit node on its own, as in §6 |
| `NODE_RECOVERY_GRACE_SECONDS` | `300` | how long a node must be unhealthy before the first attempt |
| `CORS_ORIGINS` | `*` | tighten before exposing the panel |
| `DOCS_ENABLED` | `true` | `/api/docs` serves live OpenAPI; `/api/openapi.json` is the machine-readable contract |

---

## 14. Things that will surprise you

* **`name` is the primary key in the API.** Renaming a client changes every URL. Use
  immutable IDs from your system as names.
* **Non-active clients are not on the device.** Status is enforced by removing the
  peer, so suspension is instant and total, and re-enabling reprograms it.
* **`used_*` resets, `lifetime_*` does not.** Bill on the latter.
* **Deleting a client destroys its keys.** There is no undelete; suspend instead.
* **Failover control is advisory and asynchronous.** Pins can be overridden by health,
  and take up to one probe interval to apply.
* **Editing the exit node list restarts nothing.** The node container re-reads it
  within a second and rebuilds only the interfaces that changed, so adding or removing
  a node is invisible to everyone except the users on the node being removed.
* **A total outage does not mean users are offline.** With the default
  `CASCADE_FALLBACK=direct` they stay connected and leave through the entry node's own
  address until an exit node recovers. Read `fallback_active`, not just `active`.
* **A direct route is a destination, not a client setting.** It applies to every client
  on the node, needs nothing on their side, and is invisible in their profile.
* **`endpoint` is not necessarily the endpoint you sent.** A node with both an IPv4 and
  an IPv6 endpoint is dialled on one of them, and is moved to the other if that one
  stops handshaking. Read `endpoint_family` rather than inferring it.
* **`healthy6: false` is not an outage.** An exit node that cannot reach the IPv6
  internet keeps carrying clients, who are IPv4. It is worth an alert to you and
  deliberately not a failover to SauceWG.
* **IPv6 is two switches, not one.** Dialling an exit node over IPv6 and carrying IPv6
  through the cascade are independent: either without the other is a valid, working
  configuration.
* **"The entry node has IPv6" means a routable address, not a route and not a ULA.**
  A VPS whose provider advertises a router but allocates nothing has a default route and
  nothing to send from, and the bridge's own `fd00:77::2` has global scope without being
  reachable from anywhere. Neither counts, so `endpoint_family` can read `4` on a host
  that looks IPv6-capable in `ip -6 route`.
* **A reopened destination reading `active: false` is usually correct.** In the default
  `auto` mode the redirect exists only while clients are leaving through the entry node.
  Alert on `config_error`, never on `active`.
* **A large `relay.failed` is usually one address, not a broken relay.** Some destinations
  are blocked outright rather than sampled, and no number of handshakes opens them. Read
  `cooled` alongside it: that is the relay having recognised them and stopped paying for
  them. What is worth alerting on is `via_v6` and `via_retry` both flat while `accepted`
  climbs.
* **The torrent guard is on by default,** on a new installation and on an updated one.
  It is a switch rather than a policy you opt into because the failure it prevents is
  the loss of the server, not a bill.
* **Its counters reset when the node container restarts.** They are read off the
  iptables rules, which are rebuilt at startup. Treat `blocked` as a gauge since boot,
  not as a total, and take differences rather than absolutes.
* **`mode` survives being switched off.** `{"enabled": false}` does not reset it to
  `on`, so a UI that sends the mode alongside every toggle will fight the panel.
* **Check `capabilities.string` once per node.** Without it the guard is a port filter
  and nothing more, which is not what the switch being green implies.
* **Failover does not repair.** A failed exit node stays failed until the panel's
  recovery gets it back or an operator does. `recovery.blocked == "unreachable"` is the
  one that needs a human: that server is not answering at all.
* **A recovery task that succeeds did not necessarily fix anything.** The task reports
  what the attempt found; `result.healthy` is the success condition.
* **The panel has no rate limiting.** Keep your poll loops to the cadences in §5.
* **There is no pagination cursor**, only offset/limit against a live table; a client
  created mid-scan can shift rows. Sort by `created_at asc` when you need a stable scan.
* **`/api/openapi.json` is authoritative.** If this document and the running schema
  disagree, the schema is right — generate your client from it.
