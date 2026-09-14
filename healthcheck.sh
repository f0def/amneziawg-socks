#!/usr/bin/env bash
set -euo pipefail

IFACE="${AWG_INTERFACE:-awg0}"
MAX_AGE="${AWG_MAX_HANDSHAKE_AGE:-300}"

ts="$(awg show "${IFACE}" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
[[ -n "${ts}" && "${ts}" != "0" ]] || exit 1

now="$(date +%s)"
(( now - ts < MAX_AGE ))
