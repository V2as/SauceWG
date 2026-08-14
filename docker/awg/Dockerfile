# AmneziaWG "legacy" (AWG 1.x) userspace node.
#
# The legacy line is amneziawg-go v0.2.x + amneziawg-tools v1.0.x, which speak the
# original obfuscation set (Jc/Jmin/Jmax, S1/S2, H1-H4). The v3.x line is a different
# generation of the protocol and is intentionally not used here.

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

FROM alpine:3.20 AS tools-build
ARG AWG_TOOLS_REF
RUN apk add --no-cache git make build-base linux-headers bash
WORKDIR /src
RUN git clone --depth 1 --branch "${AWG_TOOLS_REF}" https://github.com/amnezia-vpn/amneziawg-tools.git . \
    && cd src \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out WITH_BASHCOMPLETION=no WITH_WGQUICK=yes WITH_SYSTEMDUNITS=no

FROM alpine:3.20
RUN apk add --no-cache bash iproute2 iptables ip6tables nftables openresolv iputils \
    && rm -rf /var/cache/apk/*

COPY --from=go-build /out/ /
COPY --from=tools-build /out/ /
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY lib.sh /usr/local/lib/awg-lib.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/amnezia/amneziawg /var/run/amneziawg

ENV WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go \
    AWG_CONFIG_DIR=/etc/amnezia/amneziawg

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD /usr/local/bin/entrypoint.sh healthcheck

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["run"]
