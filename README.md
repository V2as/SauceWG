# SauceWG

A Marzban-style control panel for an **AmneziaWG legacy** cascade ("double VPN").

Clients connect to an entry node whose IP is not blocked by the censor. The entry node
does not reach the internet directly: it forwards everything through a second obfuscated
AmneziaWG tunnel to an exit node in another country, which performs the NAT. Both hops
speak AmneziaWG, so neither the client link nor the inter-server link looks like
WireGuard to a DPI box.

```
   client                 entry node (unblocked IP)              exit node
 ┌────────┐  AmneziaWG   ┌───────────────────────┐  AmneziaWG   ┌──────────┐
 │ phone  │ ───────────▶ │ awg0  10.8.0.1/24     │ ───────────▶ │  awg0    │ ──▶ internet
 │ laptop │   legacy     │ awg1  10.77.0.2/32    │   legacy     │ 10.77.0.1│
 └────────┘              │ panel · api · caddy   │              └──────────┘
                         └───────────────────────┘
```

## Why "legacy"

AmneziaWG has two protocol generations. This project pins the **legacy (AWG 1.x)** line —
`amneziawg-go` v0.2.x with `amneziawg-tools` v1.0.x — which uses the original obfuscation
set and is understood by every AmneziaVPN client in the wild:

| Parameter | Meaning | Must match on both sides |
| --- | --- | --- |
| `Jc` | number of junk packets sent before each handshake | no |
| `Jmin` / `Jmax` | junk packet size range in bytes | no |
| `S1` | padding of the handshake initiation (`S1 + 56 != S2`) | **yes** |
| `S2` | padding of the handshake response | **yes** |
| `H1`–`H4` | replacement values for the four packet type headers | **yes** |

The v3.x line (`I1`–`I5` signature packets, `S3`/`S4`, header protection) is deliberately
not used. The panel copies `S1`, `S2` and `H1`–`H4` verbatim into every generated client
profile, and may hand out a different junk profile via `CLIENT_JC` / `CLIENT_JMIN` /
`CLIENT_JMAX`.

## Components

| Service | Image | Role |
| --- | --- | --- |
| `awg` | `saucewg/awg` | amneziawg-go + amneziawg-tools, interfaces, routing, NAT |
| `panel` | `saucewg/panel` | FastAPI: REST API, traffic collector, peer reconciliation |
| `caddy` | `saucewg/web` | Vue 3 single-page UI + reverse proxy for `/api` and `/sub` |
| `postgres` | `postgres:16-alpine` | clients, admins, usage history |

The panel talks to the node over the AmneziaWG UAPI unix socket (a shared Docker volume),
so it needs neither the `awg` binary nor `NET_ADMIN`. The database is the source of truth:
a reconciliation loop re-applies every peer after a node restart.

## Quick start

### 1. Exit node

```bash
git clone <this repo> /opt/saucewg && cd /opt/saucewg
cp .env.exit.example .env
./scripts/bootstrap-exit.sh --port 51820 --subnet 10.77.0.0/24
```

The script prints the exit node's public key and its obfuscation profile. Keep them.

### 2. Entry node

```bash
git clone <this repo> /opt/saucewg && cd /opt/saucewg
cp .env.example .env
```

Fill in at least:

```ini
ADMIN_PASSWORD=...              # openssl rand -base64 18
JWT_SECRET=...                  # openssl rand -hex 32
POSTGRES_PASSWORD=...           # openssl rand -hex 24
AWG_ENDPOINT_HOST=<entry ip>
CASCADE_ENDPOINT=<exit ip>:51820
CASCADE_PEER_PUBLIC_KEY=<exit public key>
CASCADE_S1=...                  # mirror the exit node's AWG_S1/S2/H1-H4
```

Then:

```bash
./scripts/bootstrap-entry.sh --endpoint-host <entry ip> --cascade-endpoint <exit ip>:51820
```

### 3. Pair the two

The entry node prints its uplink public key. Put it on the exit node and restart:

```bash
# on the exit node
sed -i "s|^AWG_PEER_PUBLIC_KEY=.*|AWG_PEER_PUBLIC_KEY=<entry uplink key>|" .env
docker compose -f docker-compose.exit.yml up -d --force-recreate
```

Optionally add a pre-shared key to the uplink for post-quantum resistance: generate it
once with `docker run --rm --entrypoint awg saucewg/awg:1.0.0 genpsk`, then set
`AWG_PEER_PSK` on the exit node and `CASCADE_PEER_PSK` on the entry node.

Private keys are generated inside the node container on first start and persisted in the
`awg-config` volume. They never need to be typed into `.env`.

### 4. Sign in

Open `http://<entry ip>/` and log in with `ADMIN_USERNAME` / `ADMIN_PASSWORD`. Create a
client, then hand out the `.conf` file, the QR code, or the subscription link.

> Serving the panel over plain HTTP sends the admin password in the clear. Point a domain
> at the entry node and set `PANEL_SITE_ADDRESS=panel.example.com` with
> `CADDY_AUTO_HTTPS=on` to get an automatic Let's Encrypt certificate.

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
| `GET` | `/api/system` | host stats, client counts, live speed, cascade state |
| `GET` | `/api/system/usage?hours=` | node-wide traffic history |
| `POST` | `/api/system/sync` | force peer reconciliation |
| `GET` | `/api/settings` | interface and obfuscation parameters |
| `GET` | `/sub/{token}` | the client profile, no admin auth required |

Interactive docs are at `/api/docs` when `DOCS_ENABLED=true`.

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

A second workflow, `.github/workflows/ci.yml`, runs on pull requests and builds the
frontend, imports the backend, shellchecks the node scripts and validates both compose
files. It needs no secrets.

### From your machine

```bash
export IMAGE_AWG=yourname/saucewg-awg:1.0.0
export IMAGE_PANEL=yourname/saucewg-panel:1.0.0
export IMAGE_WEB=yourname/saucewg-web:1.0.0

make build
make push
```

Set `PLATFORMS=linux/amd64,linux/arm64` to produce the same multi-arch manifests the
workflow does.

## Operating notes

- **Kill switch.** With `CASCADE_KILLSWITCH=true` the entry node only forwards client
  traffic into the uplink interface. If the exit node is unreachable, clients lose
  connectivity instead of leaking through the entry node's own address.
- **Routing.** The entry node uses policy routing (`ip rule from <subnet> lookup 451`)
  rather than a default route, so SSH and the panel keep using the normal route.
- **Performance.** Both hops run the userspace `amneziawg-go`, which is CPU-bound. On a
  2-core VPS expect tens of Mbit/s per node. Installing the AmneziaWG kernel module on the
  host and pointing `WG_QUICK_USERSPACE_IMPLEMENTATION` at it is the usual next step if you
  outgrow that.
- **Ports.** The entry node defaults to UDP/443, which blends in with QUIC and survives
  networks that only allow well-known ports. The exit node uses UDP/51820 since only the
  entry node dials it.

## Layout

```
backend/          FastAPI service (app/awg = UAPI client, app/services = workers)
frontend/         Vue 3 + Vite single-page UI
docker/awg/       AmneziaWG legacy node image and entrypoint
docker/caddy/     frontend build + Caddy reverse proxy image
scripts/          bootstrap helpers for both node roles
.github/workflows/  CI checks and the Docker Hub publish pipeline
docker-compose.yml       entry node: awg + panel + caddy + postgres
docker-compose.exit.yml  exit node: awg only
```
