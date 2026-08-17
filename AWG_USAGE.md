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
  "killswitch": true,
  "stale": false,
  "updated_at": "2026-08-14T14:31:02Z",
  "config_error": null,
  "provisioning": true,
  "nodes": [
    {
      "name": "eu-primary",
      "iface": "awg1",
      "address": "10.77.0.2/32",
      "priority": 10,
      "endpoint": "72.56.92.184:51820",
      "exit_ip": "72.56.92.184",
      "public_key": "Lkug…=",
      "peer_public_key": "ASPc…=",
      "paired": true,
      "healthy": true,
      "active": true,
      "last_handshake_at": "2026-08-14T14:30:58Z",
      "latency_ms": 47.08,
      "rx_bytes": 3092,
      "tx_bytes": 87289,
      "managed": true,
      "ssh_host": "72.56.92.184",
      "ssh_port": 22,
      "ssh_user": "root",
      "ssh_key": true,
      "created_at": "2026-06-02T09:12:44Z",
      "task_id": null
    },
    { "name": "eu-backup", "priority": 20, "healthy": true, "active": false, "…": "…" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `priority` | **lower wins.** The healthy node with the smallest number carries traffic |
| `healthy` | passed the last health checks (see below) |
| `active` | currently carrying client traffic |
| `paired` | the exit node's key is installed here; an unpaired node can never become active |
| `public_key` | the **entry node's** key for this uplink — this is what you install on the exit node |
| `peer_public_key` | the exit node's key |
| `latency_ms` | round trip through the tunnel to `CASCADE_PROBE_TARGET` |
| `killswitch` | when `true`, clients are cut off rather than leaked via the entry IP if every uplink dies |
| `stale` | **check this.** `true` means the node container stopped publishing state, so every health field below is untrustworthy |
| `config_error` | a complete sentence explaining why the cascade is not what this panel thinks it is — a list the node container refused, or a `CASCADE_NODES_JSON` overriding the file. `null` when all is well |
| `provisioning` | `false` when this panel cannot edit the cascade, so the write calls below are refused — `403` when provisioning is switched off, `409` when `CASCADE_NODES_JSON` owns the list |
| `managed` | the panel installed this node over SSH and can reach it again |
| `ssh_host` / `ssh_port` / `ssh_user` | how it reaches it; `null` for a node added by hand |
| `ssh_key` | the panel's own key is on that server, so calls about it need no credentials |
| `task_id` | set while an install, removal or repair for this node is still running |

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

---

## 7. Node information

```http
GET /api/system
```

Host metrics, client totals, live throughput, and the cascade summary:

```json
{
  "panel_title": "SauceWG", "version": "1.3.0",
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
    "node": "eu-primary", "mode": "auto",
    "nodes_total": 2, "nodes_healthy": 2
  }
}
```

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

## 8. Errors

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

## 9. Integration recipes

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
* `nodes_healthy == 0` — every exit is down; with the kill switch armed all users are
  offline by design.
* `active` differs from the lowest-priority healthy node for a sustained period.
* `GET /api/system` → `node_ready == false` after startup.

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

## 10. Configuration reference

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
| `CASCADE_PROBE_INTERVAL` / `CASCADE_FAIL_THRESHOLD` | 10 / 3 | failover detection time |
| `CASCADE_KILLSWITCH` | `true` | whether a total uplink outage blocks users or leaks via the entry IP |
| `NODE_PROVISION_ENABLED` | `true` | `false` makes the cascade read-only through the API — see [`SAUCEWG_USAGE.md` §6](SAUCEWG_USAGE.md#6-files-on-the-server) |
| `CORS_ORIGINS` | `*` | tighten before exposing the panel |
| `DOCS_ENABLED` | `true` | `/api/docs` serves live OpenAPI; `/api/openapi.json` is the machine-readable contract |

---

## 11. Things that will surprise you

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
* **The panel has no rate limiting.** Keep your poll loops to the cadences in §5.
* **There is no pagination cursor**, only offset/limit against a live table; a client
  created mid-scan can shift rows. Sort by `created_at asc` when you need a stable scan.
* **`/api/openapi.json` is authoritative.** If this document and the running schema
  disagree, the schema is right — generate your client from it.
