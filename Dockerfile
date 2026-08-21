# syntax=docker/dockerfile:1

# ---- Stage 1: amneziawg-go (userspace WireGuard implementation with AmneziaWG obfuscation) ----
# Runs natively on the build host (--platform=$BUILDPLATFORM) and cross-compiles
# for the requested TARGETARCH via Go's own cross-compiler plus a matching gcc
# cross toolchain for the external linker. This avoids running the Go
# compiler/assembler under full-binary (QEMU) emulation, which reliably
# segfaults when e.g. building a linux/amd64 image on an arm64 Docker host
# (or vice versa).
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm AS awg-go
ARG TARGETOS
ARG TARGETARCH
ARG AWGGO_COMMIT=1b86b2ae0e493e7ea93f8c1a0f0cb6735b1551f1
RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git /awg && \
    cd /awg && git checkout ${AWGGO_COMMIT}
WORKDIR /awg
RUN go mod download && go mod verify
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) CROSS_PKGS="gcc-x86-64-linux-gnu libc6-dev-amd64-cross"; CC=x86_64-linux-gnu-gcc ;; \
        arm64) CROSS_PKGS="gcc-aarch64-linux-gnu libc6-dev-arm64-cross"; CC=aarch64-linux-gnu-gcc ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    apt-get update && apt-get install -y --no-install-recommends ${CROSS_PKGS} && rm -rf /var/lib/apt/lists/*; \
    CGO_ENABLED=1 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" CC="${CC}" \
        go build -ldflags '-linkmode external -extldflags "-static"' -v -o /usr/bin/amneziawg-go

# ---- Stage 2: amneziawg-tools (awg / awg-quick) ----
FROM alpine:3.20 AS awg-tools
RUN apk add --no-cache git build-base linux-headers
ARG AWGTOOLS_COMMIT=v3.1.20260812
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools.git /amneziawg-tools && \
    cd /amneziawg-tools && git checkout ${AWGTOOLS_COMMIT} && \
    cd src && make

# ---- Stage 3: microsocks (tiny SOCKS5 server) ----
FROM alpine:3.20 AS microsocks
RUN apk add --no-cache git build-base
RUN git clone https://github.com/rofl0r/microsocks.git /microsocks && \
    cd /microsocks && make

# ---- Final stage ----
FROM alpine:3.20

# nftables instead of iptables: awg-quick prefers `nft` when present and
# skips the iptables/ip6tables path entirely, and the legacy iptables
# package drags in libxtables/zstd-libs/libelf/libcap2 for a compat layer
# we never use (~7MB heavier for the same result). No ca-certificates:
# nothing in this image makes TLS/HTTPS connections.
RUN apk add --no-cache iproute2 nftables bash openresolv

COPY --from=awg-tools /amneziawg-tools/src/wg /usr/bin/awg
COPY --from=awg-tools /amneziawg-tools/src/wg-quick/linux.bash /usr/bin/awg-quick
RUN chmod +x /usr/bin/awg /usr/bin/awg-quick && \
    ln -s /usr/bin/awg /usr/bin/wg && \
    ln -s /usr/bin/awg-quick /usr/bin/wg-quick

COPY --from=awg-go /usr/bin/amneziawg-go /usr/bin/amneziawg-go
COPY --from=microsocks /microsocks/microsocks /usr/bin/microsocks

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV AWG_INTERFACE=awg0 \
    SOCKS5_PORT=1080 \
    SOCKS5_BIND=0.0.0.0 \
    SOCKS5_USER= \
    SOCKS5_PASS=

EXPOSE 1080/tcp

ENTRYPOINT ["/entrypoint.sh"]
