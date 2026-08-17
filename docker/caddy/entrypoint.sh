#!/bin/sh
# Turns the CADDY_AUTO_HTTPS boolean into the global option the Caddyfile expands.
#
# Caddy has no "auto_https on": automatic HTTPS is the default and is expressed by
# leaving the directive out entirely, so a boolean cannot be handed to it directly.
# Writing one there is a config adaptation error, which makes `caddy run` exit before
# it binds a port — an installation that looks finished but serves nothing.
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
		echo "entrypoint: use 'on', 'off', or one of Caddy's own auto_https values:" >&2
		echo "entrypoint: disable_redirects, disable_certs, ignore_loaded_certs, prefer_wildcard." >&2
		exit 1
		;;
esac
export CADDY_GLOBAL_OPTIONS

exec "$@"
