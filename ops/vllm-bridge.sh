#!/usr/bin/env bash
#
# Host -> vLLM container TCP bridge that RESOLVES the container IP instead of
# pinning it.
#
# Why: the vLLM container's address on nim_net is not stable. A `docker compose
# down` (e.g. the deliberate memory-reclaim step in spark-ai/README.md) deletes
# nim_net, and vLLM only reclaims 172.18.0.2 by luck of container start order.
# The bridge units used to hardcode that IP, so a move silently pointed Gandalf's
# inference at a dead address. Nothing on the Gandalf side verified it, so the
# first symptom was "Gandalf has gone quiet".
#
# spark-ai/start-all.sh repairs its OWN socat bridges on that cascade, but it has
# no business reaching into Gandalf's systemd units — that cross-world coupling is
# exactly what the consolidation is deleting. So the fix lives here: the bridge is
# correct by construction at every start, and it exits when the target moves so
# systemd (Restart=always) restarts it and re-resolves.
#
# Usage: vllm-bridge.sh <bind-ip> [listen-port] [container] [container-port]

set -uo pipefail

BIND="${1:?usage: vllm-bridge.sh <bind-ip> [listen-port] [container] [container-port]}"
LISTEN_PORT="${2:-8000}"
CONTAINER="${3:-vllm-qwen3-coder-next}"
TARGET_PORT="${4:-8000}"
POLL_SECS="${VLLM_BRIDGE_POLL_SECS:-30}"

resolve_ip() {
    docker inspect "$CONTAINER" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null
}

ip="$(resolve_ip)"
if [ -z "$ip" ]; then
    echo "vllm-bridge: container '$CONTAINER' has no IP (not running?)" >&2
    exit 1
fi

echo "vllm-bridge: ${BIND}:${LISTEN_PORT} -> ${ip}:${TARGET_PORT} (${CONTAINER})"
socat "TCP-LISTEN:${LISTEN_PORT},bind=${BIND},fork,reuseaddr" "TCP:${ip}:${TARGET_PORT}" &
socat_pid=$!

trap 'kill "$socat_pid" 2>/dev/null; exit 0' TERM INT

while :; do
    sleep "$POLL_SECS"

    if ! kill -0 "$socat_pid" 2>/dev/null; then
        wait "$socat_pid"
        exit $?
    fi

    now="$(resolve_ip)"

    # An empty result means vLLM is momentarily down or mid-restart. Hold the
    # listener rather than flapping the unit; the next poll re-checks.
    if [ -n "$now" ] && [ "$now" != "$ip" ]; then
        echo "vllm-bridge: ${CONTAINER} moved ${ip} -> ${now}; restarting to re-resolve" >&2
        kill "$socat_pid" 2>/dev/null
        wait "$socat_pid" 2>/dev/null
        exit 75
    fi
done
