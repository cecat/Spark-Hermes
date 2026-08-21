#!/usr/bin/env bash
# Start / stop / check the SECONDARY OpenShell control planes (cecat, luoji).
#
#   bash ops/agent-planes.sh start    # bring both planes + sandboxes up (idempotent)
#   bash ops/agent-planes.sh stop     # graceful, reverse order
#   bash ops/agent-planes.sh status   # report only, changes nothing
#
# Scope: this script owns ONLY the :8090 and :8091 planes. Gandalf's :8080 plane
# belongs to ops/start-all.sh and ops/shutdown.sh; this script never touches it,
# and deliberately never calls `openshell gateway select`, which would repoint
# Gandalf's tooling at the wrong plane.
#
# Why a separate script: the repo splits ops by tenant (see ops/shutdown.sh's
# ownership note). Gandalf is one tenant on a frozen v0.0.55/0.0.44 stack; these
# agents are another on v0.0.108/0.0.101. Folding them into start-all.sh would
# put two incompatible CLI versions in one script's PATH.
#
# NOTE: this does NOT start the legacy `openclaw-gateway` container that still
# serves the live cecat/luoji Slack agents. That is a separate, older stack with
# its own Docker restart policy.

set -eu

OPENSHELL_101="$HOME/gandalf-bringup/openshell-0.0.101/bin/openshell"
GATEWAY_BIN="$HOME/gandalf-bringup/openshell-0.0.101/bin/openshell-gateway"
NEMOCLAW_108="$HOME/gandalf-bringup/nemoclaw-src-v0.0.108/dist/nemoclaw.js"
NODE_BIN="$HOME/.nvm/versions/node/v22.22.3/bin/node"

# agent:port pairs. Add a line here when a 4th agent gets a 4th plane.
PLANES="cecat:8090 luoji:8091"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; RST=$'\033[0m'
info() { printf '%s[✓]%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
fail() { printf '%s[✗]%s %s\n' "$RED" "$RST" "$1"; }
note() { printf '%s[i]%s %s\n' "$CYN" "$RST" "$1"; }

# Talk to one plane. Never inherits an ambient OPENSHELL_GATEWAY.
osh() { # osh <port> <args...>
    local port="$1"; shift
    env -u OPENSHELL_GATEWAY -u OPENSHELL_GATEWAY_ENDPOINT \
        NEMOCLAW_GATEWAY_PORT="$port" \
        "$OPENSHELL_101" -g "nemoclaw-${port}" "$@"
}

gateway_up() { # gateway_up <port>
    osh "$1" sandbox list >/dev/null 2>&1
}

# Who is actually LISTENING on the port. Deliberately not the runtime.json
# marker: NemoClaw writes that at onboard time and does NOT refresh it when the
# gateway is relaunched by anything else, so after a restart it names a dead PID.
# The listener is ground truth.
gateway_pid() { # gateway_pid <port>
    local pid
    pid=$(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

sandbox_phase() { # sandbox_phase <port> <name>
    osh "$1" sandbox list 2>/dev/null | awk -v n="$2" '$1==n {print $NF}' | sed 's/\x1b\[[0-9;]*m//g'
}

# The gateway is a plain host process with no unit file. Relaunch it exactly the
# way `nemoclaw onboard` does: same binary, same state dir, same config, and the
# argv0 tag the CLI matches on (HOST_GATEWAY_PGREP_PATTERN in
# src/lib/onboard/host-gateway-process.ts).
start_gateway() { # start_gateway <port>
    local port="$1" state cfg
    state="$HOME/.local/state/nemoclaw/openshell-docker-gateway-${port}"
    cfg="$state/openshell-gateway.toml"
    [ -f "$cfg" ] || { fail "no gateway config at $cfg — was this plane ever onboarded?"; return 1; }

    OPENSHELL_GATEWAY_CONFIG="$cfg" \
    OPENSHELL_DB_URL="sqlite:$state/openshell.db" \
    OPENSHELL_SERVER_PORT="$port" \
    OPENSHELL_GRPC_ENDPOINT="https://127.0.0.1:${port}" \
    OPENSHELL_BIND_ADDRESS=127.0.0.1 \
    OPENSHELL_DRIVERS=docker \
    NEMOCLAW_OPENSHELL_SANDBOX_NAMESPACE="$(python3 - "$state" <<'PY'
import hashlib, os, sys
# Mirrors gatewayIdForStateDir(): sha256(uid \0 abspath), first 12 hex chars.
state = os.path.abspath(sys.argv[1])
leaf = os.path.basename(state)
digest = hashlib.sha256(f"{os.getuid()}\0{state}".encode()).hexdigest()[:12]
print(f"nemoclaw-{leaf}-{digest}")
PY
)" \
    setsid python3 -c '
import os, sys
# Launch with argv0 = openshell-gateway[nemoclaw=nemoclaw-<port>;port=<port>].
# NemoClaw identifies its own gateways by that exact argv0 (see
# buildOwnedHostGatewayArgv0 / OWNED_HOST_GATEWAY_ARGV0_RE in
# src/lib/onboard/gateway-process-target-identity.ts, and the anchored
# HOST_GATEWAY_PGREP_PATTERN). A gateway relaunched without it still serves
# traffic, but the CLI cannot recognise, reuse, or reap it — so `onboard
# --resume` would try to start a duplicate on a port already in use.
binary, port = sys.argv[1], sys.argv[2]
os.execv(binary, [f"openshell-gateway[nemoclaw=nemoclaw-{port};port={port}]"])
' "$GATEWAY_BIN" "$port" >>"$state/openshell-gateway.log" 2>&1 &
    local pid=$!
    printf '%s' "$pid" > "$state/openshell-gateway.pid"

    for _ in $(seq 1 40); do
        gateway_up "$port" && return 0
        sleep 1
    done
    return 1
}

# A reboot SIGKILLs sandbox containers. Same rule as Gandalf's: `docker start`
# the EXISTING container, never recreate — these sandboxes have no bind mounts,
# so the workspace (SOUL.md, memory/, runbooks) lives only in the writable layer.
start_sandbox() { # start_sandbox <port> <name>
    local port="$1" name="$2" stopped
    [ "$(sandbox_phase "$port" "$name")" = "Ready" ] && { info "$name: Ready"; return 0; }

    stopped=$(docker ps -a --filter 'status=exited' --filter 'status=created' --filter 'status=restarting' \
        --format '{{.Names}}' 2>/dev/null | grep "^openshell-default--${name}-" | head -1 || true)
    if [ -n "$stopped" ]; then
        warn "$name container not running — starting it (NOT recreating: state is in its writable layer)"
        docker start "$stopped" >/dev/null || { fail "docker start $stopped failed"; return 1; }
    fi
    for _ in $(seq 1 60); do
        [ "$(sandbox_phase "$port" "$name")" = "Ready" ] && { info "$name: Ready"; return 0; }
        sleep 2
    done
    fail "$name did not reach Ready"; return 1
}

cmd_start() {
    for entry in $PLANES; do
        local name="${entry%%:*}" port="${entry##*:}"
        echo ""; echo "=== $name (plane :$port) ==="
        if gateway_up "$port"; then
            info "gateway :$port already healthy (PID $(gateway_pid "$port" || echo '?'))"
        else
            warn "gateway :$port not responding — starting it"
            start_gateway "$port" && info "gateway :$port up (PID $(gateway_pid "$port" || echo '?'))" \
                || { fail "gateway :$port would not start — see ~/.local/state/nemoclaw/openshell-docker-gateway-$port/openshell-gateway.log"; continue; }
        fi
        start_sandbox "$port" "$name" || true
    done
}

# Consumer before producer: the sandbox first, then the gateway that manages it.
cmd_stop() {
    for entry in $PLANES; do
        local name="${entry%%:*}" port="${entry##*:}" pid con
        echo ""; echo "=== $name (plane :$port) ==="
        con=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^openshell-default--${name}-" | head -1 || true)
        if [ -n "$con" ]; then
            docker stop "$con" >/dev/null 2>&1 && info "stopped sandbox $name" || warn "could not stop $con"
        else
            note "$name sandbox already stopped"
        fi
        if pid=$(gateway_pid "$port"); then
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
            kill -0 "$pid" 2>/dev/null && { warn "gateway :$port ignored SIGTERM — sending SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
            info "stopped gateway :$port"
        else
            note "gateway :$port already stopped"
        fi
    done
}

cmd_status() {
    for entry in $PLANES; do
        local name="${entry%%:*}" port="${entry##*:}" pid phase
        echo ""; echo "=== $name (plane :$port) ==="
        if pid=$(gateway_pid "$port"); then info "gateway :$port running (PID $pid)"; else fail "gateway :$port down"; fi
        if gateway_up "$port"; then
            phase=$(sandbox_phase "$port" "$name")
            [ "$phase" = "Ready" ] && info "sandbox $name: Ready" || fail "sandbox $name: ${phase:-unknown}"
            note "inference: $(osh "$port" inference get 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*Model:[[:space:]]*//p' | head -1)"
        else
            fail "gateway :$port not answering — sandbox state unknown"
        fi
    done
}

# `openshell gateway select` writes a GLOBAL default that persists on disk, and
# several v0.0.108 commands set it as a side effect. Left pointing at :8090 or
# :8091 it silently breaks Gandalf's tooling — every bare `openshell` call then
# queries an agent plane, so his sandbox reads as "unreachable" while being
# perfectly healthy. Always hand the default back to him, whatever happened above.
restore_default_gateway() {
    local cur
    cur=$("$HOME/.local/bin/openshell" gateway list 2>/dev/null \
          | sed 's/\x1b\[[0-9;]*m//g' | awk '/^\*/ {print $2}')
    [ "$cur" = "nemoclaw" ] && return 0
    "$HOME/.local/bin/openshell" gateway select nemoclaw >/dev/null 2>&1 \
        && note "default gateway restored to 'nemoclaw' (was '${cur:-unknown}')"
}
trap restore_default_gateway EXIT

case "${1:-status}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
