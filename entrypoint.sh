#!/usr/bin/env bash
set -euo pipefail

AWG_INTERFACE="${AWG_INTERFACE:-awg0}"
# Always a container-internal, writable copy — never the user's bind-mounted
# file itself, since we sed/chmod it below and a :ro mount would reject that.
CONF_DIR="/run/amneziawg"
CONF_PATH="${CONF_DIR}/${AWG_INTERFACE}.conf"

mkdir -p "${CONF_DIR}"
chmod 700 "${CONF_DIR}"

if [[ -n "${AWG_CONF:-}" ]]; then
    printf '%s\n' "${AWG_CONF}" > "${CONF_PATH}"
elif [[ -n "${AWG_CONF_FILE:-}" && -f "${AWG_CONF_FILE}" ]]; then
    cp "${AWG_CONF_FILE}" "${CONF_PATH}"
else
    echo "[!] No AmneziaWG config supplied. Set the AWG_CONF env var to the full contents" >&2
    echo "    of your .conf file (e.g. amnezia-wg.conf), or bind-mount it and set" >&2
    echo "    AWG_CONF_FILE to that path." >&2
    exit 1
fi

# Amnezia's exporter emits empty I1-I5 lines (e.g. "I2 = ") when a junk
# handshake field is unused; amneziawg-tools' parser rejects those as
# unrecognized, so drop any empty-valued line before handing the config
# to awg-quick.
sed -i -E '/^[[:space:]]*I[1-5][[:space:]]*=[[:space:]]*$/d' "${CONF_PATH}"

# Most container runtimes (default docker bridge network, many CI/cloud
# hosts) run with IPv6 disabled at the kernel level. awg-quick hard-fails
# when asked to add an IPv6 default route in that case, so drop IPv6
# entries from AllowedIPs up front and stick to IPv4-only routing.
if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "1" ]]; then
    echo "[*] IPv6 is disabled in this container; stripping IPv6 AllowedIPs entries"
    awk '
        BEGIN { IGNORECASE = 1 }
        /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
            split($0, parts, "=")
            n = split(parts[2], ips, ",")
            out = ""
            for (i = 1; i <= n; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", ips[i])
                if (ips[i] !~ /:/) {
                    out = out (out == "" ? "" : ", ") ips[i]
                }
            }
            if (out != "") print "AllowedIPs = " out
            next
        }
        { print }
    ' "${CONF_PATH}" > "${CONF_PATH}.tmp" && mv "${CONF_PATH}.tmp" "${CONF_PATH}"
fi
chmod 600 "${CONF_PATH}"

if [[ ! -e /dev/net/tun ]]; then
    echo "[!] /dev/net/tun is missing. Run the container with --device /dev/net/tun --cap-add NET_ADMIN" >&2
    exit 1
fi

cleanup() {
    echo "[*] Shutting down..."
    [[ -n "${MICROSOCKS_PID:-}" ]] && kill "${MICROSOCKS_PID}" 2>/dev/null || true
    awg-quick down "${CONF_PATH}" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "[*] Bringing up interface ${AWG_INTERFACE} from ${CONF_PATH}"
awg-quick up "${CONF_PATH}"

SOCKS5_PORT="${SOCKS5_PORT:-1080}"
SOCKS5_BIND="${SOCKS5_BIND:-0.0.0.0}"

MICROSOCKS_ARGS=(-i "${SOCKS5_BIND}" -p "${SOCKS5_PORT}")
if [[ -n "${SOCKS5_USER:-}" ]]; then
    MICROSOCKS_ARGS+=(-u "${SOCKS5_USER}" -P "${SOCKS5_PASS:-}")
fi

echo "[*] Starting SOCKS5 proxy on ${SOCKS5_BIND}:${SOCKS5_PORT}"
microsocks "${MICROSOCKS_ARGS[@]}" &
MICROSOCKS_PID=$!

wait "${MICROSOCKS_PID}"
