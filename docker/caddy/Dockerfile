# Build context is the repository root.

# The bundle is architecture independent, so this stage stays on the build host's
# native platform instead of being emulated for every target.
FROM --platform=$BUILDPLATFORM node:22-alpine AS build
WORKDIR /app
COPY frontend/package.json ./
RUN npm install --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

FROM caddy:2.9-alpine
COPY --from=build /app/dist /srv/panel
COPY docker/caddy/Caddyfile /etc/caddy/Caddyfile
COPY docker/caddy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
EXPOSE 80 443
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
