# FIX — why `--domain` never started, and what to change

An entry node installed on `200.165.234.68` with

```bash
saucewg install --domain amazing1.apt-ubuntu.store
```

finished, printed a panel URL and a password, and left three of four containers healthy.
The fourth never stayed up:

```
1cdc3ac7dfda  v2as/saucewg-web:latest  "caddy run --config …"  Restarting (1) 8 seconds ago
```

Nothing on the box was misconfigured. The bug is in the repository, and it fires on every
installation that passes `--domain`. Plain-HTTP installs are unaffected, which is why it
went unnoticed.

## 1. Root cause

`docker logs saucewg-caddy-1` said the same thing on every one of its restarts:

```
Error: adapting config using caddyfile: parsing caddyfile tokens for 'auto_https':
auto_https must be one of 'off', 'disable_redirects', 'disable_certs',
'ignore_loaded_certs', or 'prefer_wildcard', at /etc/caddy/Caddyfile:3
```

Three pieces line up to produce it.

`saucewg.sh` turns `--domain` into a boolean:

```sh
local site_address="${http_port}" auto_https=off
if [ -n "$domain" ]; then
    site_address="$domain"
    auto_https=on          # <-- written to .env as CADDY_AUTO_HTTPS=on
fi
```

`docker-compose.yml` passes it into the container, and `docker/caddy/Caddyfile` expanded it
straight into a global option:

```
{
	admin off
	auto_https {$CADDY_AUTO_HTTPS:off}
}
```

**Caddy has no `auto_https on`.** Automatic HTTPS is the default and is expressed by leaving
the directive out entirely; the option only exists to switch it *off* or to qualify it. So
`on` — the value the installer writes, `.env.example` suggests and `README.md` documents — is
the one value that cannot appear there.

Two properties turned a typo-sized mistake into a silent failure:

- **It fails at container start, not at image build.** `{$VAR}` is substituted when the
  Caddyfile is adapted, so the image builds and pushes cleanly and only breaks on a host
  whose `.env` says `on`.
- **It fails before any port is bound.** `caddy run` exits 1 during config adaptation, the
  `restart: unless-stopped` policy brings it back, and the loop repeats forever. The panel,
  the database and the node stay healthy the whole time, so every other signal says the
  install worked.

## 2. Why nothing caught it

Worth fixing separately, because the same blind spots will hide the next one.

| Gap | Consequence |
| --- | --- |
| `wait_for_panel()` polls `panel:8000/api/health` through `compose exec` | It verifies the API container, never the reverse proxy in front of it. The one component that was dead was the one nothing checked. |
| The installer prints the URL and exits 0 regardless of container state | `compose up -d` returns once containers are *created*. A container that exits immediately is indistinguishable from a healthy one unless the state is read back. |
| CI installs with `--no-start` | Nothing is ever started, so a container that cannot start is not a test failure. |
| CI never installs with `--domain` | Both generated-compose tests run the default path, which writes `CADDY_AUTO_HTTPS=off` — the only value that worked. The TLS branch had no coverage at all. |
| Nothing adapts the Caddyfile | `docker compose config` validates compose YAML. It cannot know that a string inside an environment variable is invalid Caddy syntax. |
| `shellcheck` glob is `docker/awg/*.sh` | Anything added under `docker/caddy/` is unlinted. |

## 3. The fix

Applied in this repository; the same six changes are what another copy needs.

### 3.1 `docker/caddy/entrypoint.sh` — new

The image, not the installer, is made responsible for translating the boolean. That way
`CADDY_AUTO_HTTPS=on` is correct no matter who wrote it — the installer, a hand-edited
`.env`, or an `.env` written by an older installer that a `saucewg update` never rewrites.

```sh
#!/bin/sh
set -eu

case "$(printf '%s' "${CADDY_AUTO_HTTPS:-off}" | tr '[:upper:]' '[:lower:]')" in
	on | true | 1 | yes | enable | enabled)
		CADDY_GLOBAL_OPTIONS=''
		;;
	off | false | 0 | no | disable | disabled | '')
		CADDY_GLOBAL_OPTIONS='auto_https off'
		;;
	disable_redirects | disable_certs | ignore_loaded_certs | prefer_wildcard)
		CADDY_GLOBAL_OPTIONS="auto_https ${CADDY_AUTO_HTTPS}"
		;;
	*)
		echo "entrypoint: CADDY_AUTO_HTTPS='${CADDY_AUTO_HTTPS}' is not a value this image accepts." >&2
		exit 1
		;;
esac
export CADDY_GLOBAL_OPTIONS

exec "$@"
```

A misspelt value now stops the container with one readable line naming the variable,
instead of a Caddy parse error repeating every few seconds.

### 3.2 `docker/caddy/Caddyfile`

The boolean is gone from the global block; what expands there is now the directive itself,
and an empty expansion is what "automatic HTTPS, please" looks like in Caddy.

```
{
	admin off
	{$CADDY_GLOBAL_OPTIONS:auto_https off}
}
```

The `:auto_https off` default keeps the file valid on its own, so the image still builds and
runs with no environment at all.

### 3.3 `docker/caddy/Dockerfile`

```dockerfile
COPY docker/caddy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
EXPOSE 80 443
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
```

`caddy validate` at build time turns a broken Caddyfile into a failed build rather than a
restart loop on somebody's server. Because the base image's `ENTRYPOINT` is replaced, `CMD`
has to be restated in full — otherwise the container starts with no arguments to `exec`.

### 3.4 `saucewg.sh` — read the container states back

The installer's own reporting was wrong, independent of Caddy. A new `wait_for_containers()`
polls `compose ps` for a minute and names anything not `running`, printing the last lines of
its log:

```sh
wait_for_containers() {
    local tries=0 broken=""
    while [ "$tries" -lt 20 ]; do
        broken=$(compose ps --format json 2>/dev/null | jq -rs '
            map(select((.State // "") != "running"))
            | map("\(.Service // .Name) (\(.State // "unknown"))") | join(", ")' 2>/dev/null) \
            || broken=""
        [ -z "$broken" ] && return 0
        tries=$((tries + 1))
        sleep 3
    done
    warn "not running a minute after startup: ${broken}"
    ...
}
```

Called from `cmd_install` and from `cmd_update`, both of which now track a `healthy` flag
that reaches the summary and the `--json` output:

- the human summary gains `Some containers are not running, so <url> will not answer yet`,
  while still printing the credentials, which are valid and already on disk;
- `{"ok": …}` becomes `false` instead of an unconditional `true`, so a bot driving the
  install (`SAUCEWG_USAGE.md` §5) can tell the difference;
- `saucewg update` says the new images run worse than the ones they replaced, and how to
  pin the previous tag.

### 3.5 `scripts/test-caddy-config.sh` — new, wired into CI

Builds the final stage of the web image and adapts the config for every value the tree can
produce, asserting the resulting JSON rather than just the exit status — `on` has to yield
`:443` with automatic HTTPS untouched, `off` has to yield `:80` with it disabled. The set of
values is *read out of `saucewg.sh`*, so a third branch on `--domain` cannot be added
without this test seeing it.

Against the code as it shipped, it reports `12 passed, 12 failed`, including the exact
production error. Against the fix, `26 passed, 0 failed`.

### 3.6 `.github/workflows/ci.yml`

```yaml
- shellcheck -x -S warning saucewg.sh docker/*/*.sh scripts/*.sh   # was docker/awg/*.sh

# in the compose job, after the existing generated-compose checks:
sudo bash saucewg.sh --dir /tmp/entry-tls --yes install \
  --domain panel.example.com --endpoint-host 127.0.0.1 \
  --admin-password ci-password --no-start
sudo docker compose --project-directory /tmp/entry-tls \
  -f /tmp/entry-tls/docker-compose.yml --env-file /tmp/entry-tls/.env config >/dev/null

- name: The web container accepts every CADDY_AUTO_HTTPS the tree writes
  run: ./scripts/test-caddy-config.sh
```

### 3.7 Documentation

`.env.example` now states the accepted values next to the key, and `README.md` says what
`--domain` requires before it is used: the name has to resolve to the server and TCP/80 has
to be reachable, because that is the address the certificate is issued over.

## 4. What was done to the live server

The Caddyfile is baked into `v2as/saucewg-web:latest`, so the real fix only reaches
`200.165.234.68` once that image is rebuilt and pushed. To restore service now without a new
image, `/opt/saucewg/.env` was changed to the one native token that leaves automatic HTTPS
fully on (a backup of the original is beside it as `.env.bak-<timestamp>`):

```diff
-CADDY_AUTO_HTTPS=on
+CADDY_AUTO_HTTPS=ignore_loaded_certs
```

`ignore_loaded_certs` means "manage certificates even for names that already have a manually
loaded one". This deployment never loads a certificate by hand, so it is a no-op that
happens to be spelled in a way the parser accepts. Then:

```bash
cd /opt/saucewg && docker compose up -d caddy
```

Caddy came up, solved the HTTP-01 challenge and got a certificate. Verified from outside:

| Check | Result |
| --- | --- |
| `https://amazing1.apt-ubuntu.store/` | `200`, TLS verified |
| `http://amazing1.apt-ubuntu.store/` | `308` to HTTPS |
| `https://amazing1.apt-ubuntu.store/api/health` | `{"status":"ok","version":"1.3.0"}` |
| Certificate | `CN=amazing1.apt-ubuntu.store`, Let's Encrypt, valid to 15 Nov 2026 |
| Containers | all four `Up`, no restarts |

That value is forward-compatible: the new entrypoint passes it through unchanged. Once the
rebuilt image is published, `saucewg update` will pick it up, and the `.env` can be put back
to the documented `CADDY_AUTO_HTTPS=on` at any point after that.

## 5. Order to apply this in

1. Land the six changes above.
2. Run `./scripts/test-caddy-config.sh` locally — it needs only Docker and jq, and it fails
   loudly on the unfixed tree, so it is worth running before the fix as well to see it catch
   the bug.
3. Push to `main` and let `docker-publish.yml` rebuild all three images.
4. On existing servers: `saucewg update`, then set `CADDY_AUTO_HTTPS=on` in `/opt/saucewg/.env`
   and `saucewg restart` if the hotfix value was used.
5. New servers need nothing special — `install --domain` works from that point on.

## 6. Before installing the next server

- Point the domain's `A` record at the server and confirm it resolves *from the server*
  (`getent hosts <domain>`) before running the installer. ACME HTTP-01 needs the name to
  reach this host on TCP/80, and a certificate that cannot be issued is a different failure
  with the same symptom: nothing on port 443.
- Leave `PANEL_HTTP_PORT=80`. Let's Encrypt validates on port 80 and nowhere else, so a
  remapped host port means the challenge never arrives.
- After any install or update, confirm the front door rather than the API:
  `curl -sS -o /dev/null -w '%{http_code}\n' https://<domain>/` and `docker ps` showing no
  `Restarting`. `saucewg status` prints both.
