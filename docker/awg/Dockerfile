# AmneziaWG userspace node.
#
# amneziawg-go v3.x + amneziawg-tools v3.x implement every generation there is: 1.0
# (Jc/Jmin/Jmax, S1/S2, H1-H4), 1.5 (plus I1), 2.0 (plus S3/S4), 3.0 (plus header
# protection, content padding and randomised timings) and 3.1 (plus RandomTrailers and
# DisableCookies). A profile without the 3.x parameters is the same on the wire as it
# was under v0.2, so routers and apps that stop at 2.0 keep connecting. Which
# generation an interface speaks is decided per interface at runtime by entrypoint.sh,
# so one image serves all five.

ARG AWG_GO_REF=v3.1.20260828
ARG AWG_TOOLS_REF=v3.1.20260812

# Go cross-compiles, so this stage runs natively on the build host even when the
# target is a different architecture. amneziawg-go v3 needs Go 1.25.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS go-build
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
ARG AWG_GO_REF
ARG AWG_TOOLS_REF
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
COPY speedlimit.sh /usr/local/lib/awg-speedlimit.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/amnezia/amneziawg /var/run/amneziawg

# AWG_GENERATIONS is how saucewg on the host tells, before recreating a container,
# whether the image it is about to run can serve the generation it is being asked
# for. It has to list what lib.sh accepts.
ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go \
    AWG_CONFIG_DIR=/etc/amnezia/amneziawg \
    AWG_GENERATIONS="1.0 1.5 2.0 3.0 3.1" \
    AWG_GO_VERSION=${AWG_GO_REF} \
    AWG_TOOLS_VERSION=${AWG_TOOLS_REF}

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD /usr/local/bin/entrypoint.sh healthcheck

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["run"]
