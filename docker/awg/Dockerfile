# AmneziaWG userspace node.
#
# amneziawg-go v0.2.x + amneziawg-tools v1.0.x implement every generation a router can
# load: 1.0 (Jc/Jmin/Jmax, S1/S2, H1-H4), 1.5 (plus I1) and 2.0 (plus S3/S4). Which one
# an interface speaks is decided per interface at runtime by entrypoint.sh, so one image
# serves all three. The v3.x line is a protocol no router firmware speaks and is
# intentionally not built here.

ARG AWG_GO_REF=v0.2.19
ARG AWG_TOOLS_REF=v1.0.20260618-2

# Go cross-compiles, so this stage runs natively on the build host even when the
# target is a different architecture.
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS go-build
ARG AWG_GO_REF
ARG TARGETOS
ARG TARGETARCH
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch "${AWG_GO_REF}" https://github.com/amnezia-vpn/amneziawg-go.git . \
    && mkdir -p /out/usr/bin \
    && CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH:-amd64}" \
       go build -trimpath -ldflags "-s -w" -o /out/usr/bin/amneziawg-go \
    && chmod 0755 /out/usr/bin/amneziawg-go

# The bypass relay. Stdlib only, so it builds offline once the base image is
# cached, and it is built here rather than in its own stage to reuse the
# toolchain that is already present.
WORKDIR /src/bypass
COPY bypass/go.mod bypass/main.go ./
RUN CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH:-amd64}" \
       go build -trimpath -ldflags "-s -w" -o /out/usr/bin/awg-bypass . \
    && chmod 0755 /out/usr/bin/awg-bypass

FROM alpine:3.20 AS tools-build
ARG AWG_TOOLS_REF
RUN apk add --no-cache git make build-base linux-headers bash
WORKDIR /src
RUN git clone --depth 1 --branch "${AWG_TOOLS_REF}" https://github.com/amnezia-vpn/amneziawg-tools.git . \
    && cd src \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out WITH_BASHCOMPLETION=no WITH_WGQUICK=yes WITH_SYSTEMDUNITS=no

FROM alpine:3.20
# jq parses the exit node list and renders the uplink state file; conntrack-tools
# drops stale NAT bindings when the active uplink changes. ipset holds the
# addresses the torrent filter has caught, which is what carries a block across a
# reconnection it can no longer read inside.
RUN apk add --no-cache bash iproute2 iptables ip6tables ipset nftables openresolv iputils \
        jq conntrack-tools \
    && rm -rf /var/cache/apk/*

COPY --from=go-build /out/ /
COPY --from=tools-build /out/ /
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY lib.sh /usr/local/lib/awg-lib.sh
COPY uplinks.sh /usr/local/lib/awg-uplinks.sh
COPY torrents.sh /usr/local/lib/awg-torrents.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/amnezia/amneziawg /var/run/amneziawg

ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go \
    AWG_CONFIG_DIR=/etc/amnezia/amneziawg

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD /usr/local/bin/entrypoint.sh healthcheck

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["run"]
