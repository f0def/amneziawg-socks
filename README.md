# amneziawg-socks

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small Docker image (Alpine-based) that:

1. Brings up an AmneziaWG VPN tunnel (including the `Jc`/`Jmin`/`Jmax`,
   `S1`-`S4`, `H1`-`H4`, `I1`-`I5` fields from AmneziaWG 2.0) using
   [`amneziawg-go`](https://github.com/amnezia-vpn/amneziawg-go) (userspace
   implementation) and
   [`amneziawg-tools`](https://github.com/amnezia-vpn/amneziawg-tools)
   (`awg`/`awg-quick`).
2. Runs a SOCKS5 proxy inside the container
   ([`microsocks`](https://github.com/rofl0r/microsocks)) whose traffic is
   fully routed through the tunnel.
3. Runs an HTTP/HTTPS proxy ([`privoxy`](https://www.privoxy.org/)) that
   forwards everything to the SOCKS5 proxy above — for clients that only
   speak HTTP proxying (`HTTP_PROXY`/`HTTPS_PROXY`), not SOCKS.

The config is supplied from the outside via an environment variable or a
bind mount — your `.conf` file is never baked into the image.

## Build

`docker-compose.yml` runs an already-built image and doesn't build anything
itself, so before the first run (and after any `Dockerfile` change) you need
to build and tag the image the way the compose file expects:

```sh
docker build -t amneziawg-socks:latest .
```

CI (`.github/workflows/docker-build.yml`) builds the image for both
`linux/amd64` and `linux/arm64` on every push/PR, purely as a sanity check
that the Dockerfile isn't broken.

The image is multi-stage: `amneziawg-go` is built from source (Go),
`amneziawg-tools` from source (C), `microsocks` from source (C). The final
layer is plain `alpine:3.20` plus the compiled binaries — no compilers,
no `git`/`build-base`/headers, all of that stays behind in the discarded
build stages. Final image size is around 35 MB.

The final layer only installs what's actually needed at runtime:
`iproute2` (routing), `nftables` (policy routing rules `awg-quick` sets up
for the tunnel), `bash` (required by the `awg-quick` script), `openresolv`
(DNS via `resolvconf`), and `privoxy` (HTTP proxy front-end). There's no
`ca-certificates` — neither the tunnel nor the proxies make any HTTPS calls
of their own (privoxy only relays HTTPS via `CONNECT`, it never terminates
TLS).

The `amneziawg-go` stage builds natively on the build host's architecture
and cross-compiles for the requested target (`linux/amd64` or
`linux/arm64`) — this keeps the Go toolchain from ever running under QEMU
emulation, which reliably segfaults when building for an architecture other
than the host's.

### If `docker build` fails at the image export step

```
ERROR: no match for platform in manifest ...: not found
```

This is a known buildx bug: the provenance/SBOM attestation manifests that
buildx attaches by default sometimes break exporting the image into the
local Docker image store. Fix:

```sh
BUILDX_NO_DEFAULT_ATTESTATIONS=1 docker build -t amneziawg-socks:latest .
```

A `.env` file won't help here — this variable needs to be in the actual
`docker` process environment, not just available for interpolation inside
`docker-compose.yml`. Easiest fix if this bites you often: export it in
your shell profile (`~/.zshrc`/`~/.bashrc`).

## Run

```sh
CONF="$(cat amnezia-wg.conf)"

docker run -d --name amneziawg-socks \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -e AWG_CONF="$CONF" \
  -e SOCKS5_PORT=1080 \
  -p 1080:1080 \
  -p 8118:8118 \
  amneziawg-socks
```

The SOCKS5 proxy will be available at `socks5://<host>:1080`, and the HTTP
proxy at `http://<host>:8118`.

Check it (traffic should come out via the VPN server's IP):

```sh
curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
curl -x http://127.0.0.1:8118 https://ifconfig.me
```

### If the container fails on `src_valid_mark: Read-only file system`

On some hosts (Docker Desktop/Colima on the default bridge network,
restricted VMs) the kernel won't let you flip this sysctl from inside the
container even with `--sysctl` and `NET_ADMIN`. In that case run with
`--privileged` instead of `--cap-add NET_ADMIN --sysctl ...`:

```sh
docker run -d --name amneziawg-socks \
  --privileged \
  -e AWG_CONF="$CONF" \
  -p 1080:1080 \
  -p 8118:8118 \
  amneziawg-socks
```

On a regular Linux host (VPS/bare metal) `--cap-add NET_ADMIN --device
/dev/net/tun --sysctl net.ipv4.conf.all.src_valid_mark=1` is usually enough
without `--privileged`.

## Environment variables

| Variable         | Default      | Description                                                                |
|-------------------|--------------|----------------------------------------------------------------------------|
| `AWG_CONF`        | —            | Full contents of your AmneziaWG `.conf` file (required unless using the below) |
| `AWG_CONF_FILE`    | —            | Path to a mounted config file inside the container (alternative to `AWG_CONF`) |
| `AWG_INTERFACE`    | `awg0`       | Interface name                                                             |
| `SOCKS5_PORT`      | `1080`       | SOCKS5 proxy port                                                          |
| `SOCKS5_BIND`      | `0.0.0.0`    | Address the proxy listens on inside the container                         |
| `SOCKS5_USER`      | —            | Username for proxy auth (optional)                                        |
| `SOCKS5_PASS`      | —            | Password for proxy auth (optional, used together with `SOCKS5_USER`)      |
| `HTTP_PROXY_ENABLED` | `1`        | Set to `0` to disable the HTTP proxy and only run SOCKS5                   |
| `HTTP_PROXY_PORT`  | `8118`       | HTTP proxy port (`privoxy`, forwards to the SOCKS5 proxy above)            |
| `HTTP_PROXY_BIND`  | `0.0.0.0`    | Address the HTTP proxy listens on inside the container                    |
| `AWG_MAX_HANDSHAKE_AGE` | `300`   | Seconds since the last WireGuard handshake before the container is considered dead (see "Self-healing" below) |
| `AWG_WATCHDOG_INTERVAL` | `60`    | How often (seconds) the watchdog checks handshake freshness                |

The HTTP proxy has no auth of its own — it's meant for local/trusted use in
front of the already-authenticated SOCKS5 proxy. If you need it exposed
beyond that, put it behind something that can authenticate requests
(e.g. a reverse proxy).

Instead of `AWG_CONF` you can bind-mount the config file (it stays read-only
outside the container; the entrypoint copies it into an internal writable
copy itself):

```sh
docker run ... \
  -v $PWD/amnezia-wg.conf:/conf/awg0.conf:ro \
  -e AWG_CONF_FILE=/conf/awg0.conf \
  amneziawg-socks
```

## docker-compose

`docker-compose.yml` expects an already-built `amneziawg-socks:latest`
image (there's deliberately no `build:` section — build the image first,
see "Build" above). It already sets up a volume mount of `amnezia-wg.conf`
to `/conf/awg0.conf` (read-only) and `AWG_CONF_FILE=/conf/awg0.conf`. If
your config file has a different name, adjust the path under `volumes:`.
Run:

```sh
docker compose up -d
```

## Self-healing

If the host's network drops and comes back (Wi-Fi roaming, VPN toggle,
laptop sleep/wake, ...), a WireGuard tunnel's UDP socket can end up wedged
with no handshake and no way to recover on its own, silently leaving a dead
proxy running. A background watchdog checks `awg show <iface>
latest-handshakes` every `AWG_WATCHDOG_INTERVAL` seconds and, if it's older
than `AWG_MAX_HANDSHAKE_AGE`, exits the container so `restart:
unless-stopped` (or `--restart unless-stopped`) brings up a fresh interface.
The default 300s threshold is well above WireGuard's own ~120-180s rekey
cycle, so it won't fire during normal operation.

The same check is also wired up as a Docker `HEALTHCHECK`
(`docker ps`/`docker compose ps` will show `unhealthy` if the tunnel is
stuck), independent of the watchdog's own restart trigger.

## Implementation notes

- Empty `I1`-`I5` fields (which the AmneziaWG 2.0 client sometimes exports
  as `I2 = ` with no value) are automatically stripped from the config
  before startup — `amneziawg-tools`' parser rejects lines like that.
- If IPv6 is disabled inside the container (common for Docker: default
  bridge network, most cloud hosts), `::/0` is automatically dropped from
  `AllowedIPs` so `awg-quick` doesn't fail while adding the IPv6 route.
  The full IPv4 tunnel keeps working either way.
- On container stop (`SIGTERM`) the interface is torn down cleanly
  (`awg-quick down`) and both `microsocks` and `privoxy` are terminated.
- `privoxy` loads no `default.action`/`default.filter` files — it does no
  ad-blocking or content rewriting of its own, it's purely an HTTP-to-SOCKS5
  protocol front-end.
- If either proxy process dies, the container exits so its restart policy
  brings both back up together, rather than leaving a half-dead proxy pair
  running.

## License

[MIT](LICENSE)
