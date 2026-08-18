#!/usr/bin/env bash
set -euo pipefail
#
# Idempotent restorer for the Spark-Hermes Gandalf stack.
# Safe to run any time. Inspects each layer, restarts only what's broken.
# Modeled on ~/code/spark-ai/start-all.sh.
#
# Stack (bottom-up):
#
#   vLLM container (vllm-qwen3-coder-next)        ── shared with OpenClaw, not managed here
#   argo-shim (127.0.0.1:44497)                   ── self-manages its own SSH tunnel
#   socat 172.18.0.1:8000 → 172.18.0.2:8000       ── existing OpenClaw vLLM bridge (not ours)
#   socat 127.0.0.1:8000 → 172.18.0.2:8000        ── gandalf-vllm-bridge.service
#   socat 172.19.0.1:8000 → 172.18.0.2:8000       ── gandalf-vllm-bridge-openshell.service
#   socat 172.19.0.1:44497 → 127.0.0.1:44497      ── gandalf-argo-bridge.service
#   LiteLLM proxy (127.0.0.1:4000)                ── gandalf-litellm.service (Claude+vLLM router)
#   socat 172.19.0.1:4000 → 127.0.0.1:4000        ── gandalf-litellm-bridge.service
#   gandalf sandbox container                     ── NemoClaw / OpenShell
#   Hermes Agent gateway (127.0.0.1:8642)         ── inside the sandbox
#
# Deep health checks: each layer does a real end-to-end call, not just "is it listening".
# This catches "process up but rejecting requests" bugs.

# ── Colors / helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[…]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
note()  { printf "${CYAN}[i]${NC} %s\n" "$*"; }

# Distinct from the generic failure exit 1 so callers can tell "argo-shim is
# down, a human must run ~/start-all.sh" apart from a real stack fault.
EXIT_ARGO_DOWN=3

# Ensure CLIs on PATH
case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

# systemd-user env (so this works from any shell, not just login shells)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# Overridable so the argo-down path can be exercised against a dead port
# without touching the real shim on 44497.
ARGO_PORT="${ARGO_PORT:-44497}"

# Tracking flag so a lower-layer restart can cascade upward
LITELLM_RESTARTED=false

wait_for() {
    # wait_for "<description>" <max_seconds> <command...>
    local desc=$1 max=$2; shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$max" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "\r${YELLOW}[…]${NC} %s — %ds/%ds..." "$desc" "$elapsed" "$max"
    done
    echo ""
    return 1
}

# ── Deep health check primitives ────────────────────────────────────────────

# Real chat-completions call against argo-shim's /v1/messages — catches
# "shim up but tunnel down" by hitting Argo upstream.
argo_shim_healthy() {
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "http://127.0.0.1:${ARGO_PORT}/v1/messages" \
        -H "Content-Type: application/json" \
        -d '{"model":"claudehaiku45","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

# LiteLLM proxy round-trips a tiny Claude request through to Argo.
litellm_healthy() {
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
        -X POST "http://127.0.0.1:4000/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model":"claudehaiku45","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

# The OpenShell docker-driver gateway daemon (127.0.0.1:8080) does NOT autostart
# at boot. While it's down every `openshell` call fails with "transport error /
# Connection refused", which is indistinguishable from "sandbox doesn't exist"
# unless you check for it explicitly.
openshell_daemon_up() {
    openshell sandbox list >/dev/null 2>&1
}

# `nemohermes gandalf status` starts the daemon as a side effect.
ensure_openshell_daemon() {
    openshell_daemon_up && return 0
    warn "OpenShell gateway daemon not responding — starting it"
    nemohermes gandalf status >/dev/null 2>&1 || true
    wait_for "OpenShell daemon warming up" 30 openshell_daemon_up
}

# Sandbox phase, or empty if the daemon is unreachable. Callers must distinguish
# "" (can't tell) from "Error"/"Ready".
sandbox_phase() {
    openshell sandbox list 2>/dev/null | awk '/^gandalf/ {print $NF}' | sed 's/\x1b\[[0-9;]*m//g'
}

sandbox_ready() {
    [ "$(sandbox_phase)" = "Ready" ]
}

# The api_server gained an auth key (platforms.api_server.extra.key) with the
# phase0 work; without the bearer token every request is a 401. Same file
# ops/phase0-runner.py treats as canonical.
API_KEY_FILE="$HOME/.config/falda/phase0-api-key.env"
gateway_auth_header() {
    [ -f "$API_KEY_FILE" ] || return 0
    local k
    k=$(sed -n 's/^API_SERVER_KEY=//p' "$API_KEY_FILE" | head -1)
    [ -n "$k" ] && printf 'Authorization: Bearer %s' "$k"
}

# Hermes Agent gateway returns a model list AND a real chat round-trip works.
hermes_gateway_healthy() {
    local auth; auth=$(gateway_auth_header)
    curl -sf --max-time 5 -H "$auth" "http://127.0.0.1:8642/v1/models" >/dev/null 2>&1 || return 1
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 \
        -X POST "http://127.0.0.1:8642/v1/chat/completions" \
        -H "$auth" \
        -H "Content-Type: application/json" \
        -d '{"model":"hermes-agent","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

# ── Layer 0: argo-shim (VERIFY ONLY — this script does not own it) ──────────
#
# Layer 1 owner is ~/start-all.sh. This script used to start and pkill the shim
# itself, which was wrong: the probe is a live LLM round-trip over an SSH tunnel
# to Argonne, so ordinary latency reads as "dead" and a single failed sample was
# enough to kill a healthy shim. argo-shim's ssh uses BatchMode=yes and cannot
# re-auth on its own, and its SSHAttemptTracker exists because CSPO blocks the
# source IP after repeated failed auth — so a stray killer is expensive. Since
# argo-shim 0.3.20 that tracker persists to ~/.claude/argo-shim-state.json and
# survives restarts, so repeated failures escalate to a cooldown and hard lock
# rather than resetting with each new process.
#
# Verify, never start, never kill.

ensure_argo_shim() {
    echo ""; echo "=== argo-shim (127.0.0.1:${ARGO_PORT}) — verify only ==="

    if argo_shim_healthy; then
        info "argo-shim healthy (Argo round-trip returns 200)"
        return
    fi

    warn "argo-shim probe failed — re-confirming for 20s before declaring it down"
    if wait_for "re-confirming argo-shim" 20 argo_shim_healthy; then
        echo ""; info "argo-shim healthy (recovered on re-probe — first sample was a blip)"
        return
    fi

    # LiteLLM and the Hermes gateway both route through the shim, so continuing
    # would report derived failures and restart healthy services. Stop here.
    echo ""
    echo "Last 20 lines of $HOME/code/spark-ai/argo-shim.log:"
    tail -20 "$HOME/code/spark-ai/argo-shim.log" 2>&1 || true
    echo ""
    warn "argo-shim is DOWN, and this script is not its owner."
    warn "Run the Layer 1 owner from an interactive terminal:  ~/start-all.sh"
    exit "$EXIT_ARGO_DOWN"
}

# ── Layer 1: vLLM reachability (we don't manage the container itself) ───────

ensure_vllm_reachable() {
    echo ""; echo "=== vLLM container (shared with OpenClaw stack) ==="

    if ! docker ps --format '{{.Names}}' | grep -q '^vllm-qwen3-coder-next$'; then
        warn "vLLM container not running — start the OpenClaw stack:"
        warn "  bash ~/code/spark-ai/start-all.sh"
        fail "Spark-Hermes depends on the OpenClaw stack's vLLM. Bring that up first."
    fi

    local ip
    ip=$(docker inspect vllm-qwen3-coder-next \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null) || \
        fail "Could not inspect vLLM container"
    [ -n "$ip" ] || fail "vLLM container has no IP"

    if ! curl -sf --max-time 5 "http://${ip}:8000/health" >/dev/null 2>&1; then
        fail "vLLM container is running but /health is failing. Check with: docker logs vllm-qwen3-coder-next --tail 30"
    fi

    info "vLLM container reachable at ${ip}:8000"
    note "If ${ip} ever changes (vLLM rebuild), update bringup/40-vllm-bridge/*.service ExecStart lines."
}

# ── Layer 2: host-side socat bridges ────────────────────────────────────────

ensure_bridge_unit() {
    # ensure_bridge_unit <unit-name> <description>
    #
    # Return code is a SIGNAL, not success/failure: 0 = was already active,
    # 1 = we had to start it (so callers can cascade). A genuine failure calls
    # fail() and exits. Because this script runs under `set -e`, every call site
    # MUST consume that 1 — either `if ! ensure_bridge_unit ...` or `|| true`.
    # A bare call aborts the script the first time a bridge isn't already up.
    local unit=$1 desc=$2
    if systemctl --user is-active "$unit" >/dev/null 2>&1; then
        info "$unit active ($desc)"
        return 0
    fi
    warn "$unit not active — starting"
    systemctl --user start "$unit" || fail "Could not start $unit"
    sleep 1
    if systemctl --user is-active "$unit" >/dev/null 2>&1; then
        info "$unit started ($desc)"
        return 1   # restarted
    fi
    fail "$unit failed to start"
}

ensure_bridges() {
    echo ""; echo "=== host-side socat bridges (vLLM + Argo) ==="

    # vLLM bridges — needed for Gandalf sandbox to reach vLLM via host.openshell.internal:8000
    # Nothing cascades off these, so the return-1 ("started it") signal is just consumed.
    ensure_bridge_unit gandalf-vllm-bridge.service "127.0.0.1:8000 → vLLM" || true
    ensure_bridge_unit gandalf-vllm-bridge-openshell.service "172.19.0.1:8000 → vLLM" || true

    # Argo bridge — needed because LiteLLM is on host but argo-shim is also on host;
    # this one isn't strictly required for LiteLLM (talks to 127.0.0.1:44497 directly)
    # but it's harmless and useful if anything inside the sandbox ever wants direct shim access.
    #
    # `|| true` is REQUIRED, not defensive: ensure_bridge_unit returns 1 to mean "I
    # started it" (0 = was already active). Under `set -e` a bare call therefore
    # aborts this script whenever the bridge wasn't already up — which is exactly the
    # post-reboot case — silently skipping LiteLLM, the sandbox and the Hermes gateway.
    # The two calls above are guarded by `if !` for the same reason.
    ensure_bridge_unit gandalf-argo-bridge.service "172.19.0.1:44497 → argo-shim" || true
}

# ── Layer 3: LiteLLM proxy ──────────────────────────────────────────────────

ensure_litellm() {
    echo ""; echo "=== LiteLLM proxy (127.0.0.1:4000) ==="

    # Set when the health probe recovers on a second look, so the restart
    # branch below is skipped without also skipping the bridge check that
    # follows this block.
    local litellm_ok=false
    if systemctl --user is-active gandalf-litellm.service >/dev/null 2>&1 && litellm_healthy; then
        info "LiteLLM healthy (Claude round-trip returns 200)"
        litellm_ok=true
    elif systemctl --user is-active gandalf-litellm.service >/dev/null 2>&1; then
        # Re-confirm before restarting: litellm_healthy round-trips through
        # argo-shim to Argonne, so upstream latency looks like a dead proxy.
        warn "LiteLLM health failed — re-confirming for 20s before restarting"
        if wait_for "re-confirming LiteLLM" 20 litellm_healthy; then
            echo ""; info "LiteLLM healthy (recovered on re-probe — not restarting)"
            litellm_ok=true
        fi
    fi

    if ! $litellm_ok; then
        if systemctl --user is-active gandalf-litellm.service >/dev/null 2>&1; then
            echo ""
            warn "LiteLLM confirmed unhealthy — restarting"
            systemctl --user restart gandalf-litellm.service
        else
            warn "Starting LiteLLM..."
            systemctl --user start gandalf-litellm.service
        fi

        if wait_for "LiteLLM warming up" 30 litellm_healthy; then
            echo ""; info "LiteLLM ready"
            LITELLM_RESTARTED=true
        else
            echo ""
            echo "Last 20 lines of LiteLLM log:"
            tail -20 "$HOME/code/Spark-Hermes/runlog/litellm.log" 2>/dev/null || true
            fail "LiteLLM did not become healthy within 30s"
        fi
    fi

    # The LiteLLM bridge (socat 172.19.0.1:4000 → 127.0.0.1:4000) — sandbox uses this.
    if $LITELLM_RESTARTED; then
        warn "LiteLLM was restarted — restarting bridge so it reconnects"
        systemctl --user restart gandalf-litellm-bridge.service 2>/dev/null || \
            systemctl --user start gandalf-litellm-bridge.service
    else
        ensure_bridge_unit gandalf-litellm-bridge.service "172.19.0.1:4000 → LiteLLM" >/dev/null || true
        info "LiteLLM bridge active"
    fi
}

# ── Layer 4: Gandalf sandbox ────────────────────────────────────────────────

ensure_sandbox() {
    echo ""; echo "=== Gandalf sandbox ==="

    if ! command -v openshell >/dev/null 2>&1; then
        fail "openshell CLI not found — run bringup/10-install-nemoclaw.sh"
    fi

    ensure_openshell_daemon || fail "OpenShell gateway daemon (127.0.0.1:8080) would not start — check ~/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log"

    if sandbox_ready; then
        info "sandbox phase: Ready"
        return
    fi

    # A host reboot SIGKILLs the container (exit 137). Its restart policy is
    # unless-stopped, but a clean shutdown counts as "stopped", so Docker never
    # brings it back and OpenShell latches Phase=Error/ContainerExited forever.
    #
    # This MUST be `docker start` on the existing container, never a recreate or
    # `nemohermes gandalf rebuild`: the sandbox has NO bind mounts, so all of
    # /sandbox/.hermes (including the hand-injected platforms.* blocks that make
    # Slack/Telegram inbound work) lives only in its writable layer.
    local stopped
    # `|| true`: no match is the normal "nothing to recover" case, but grep's
    # exit 1 would trip set -e and abort before the diagnostic below.
    #
    # Match any non-running state, not just `exited`: a container Docker is still
    # restarting after a reboot reports `created` or `restarting`, and an
    # exited-only filter reports it missing (see DGX-Spark/ops/boot-recover-sandbox.sh).
    stopped=$(docker ps -a --filter 'status=exited' --filter 'status=created' --filter 'status=restarting' \
        --format '{{.Names}}' 2>/dev/null | grep '^openshell-gandalf-' | head -1 || true)
    if [ -n "$stopped" ]; then
        warn "sandbox container not running — starting it (NOT rebuilding: state lives in its writable layer)"
        docker start "$stopped" >/dev/null || fail "docker start $stopped failed"
        if wait_for "sandbox coming up" 60 sandbox_ready; then
            echo ""; info "sandbox phase: Ready"; return
        fi
        echo ""
    fi

    # Sandbox exists but not Ready — try recover (gateway restart). If it
    # doesn't exist at all, that's a bringup issue, not a daily-restore issue.
    if openshell sandbox list 2>/dev/null | grep -q '^gandalf'; then
        warn "sandbox exists but not Ready — running nemohermes gandalf recover"
        nohup nemohermes gandalf recover >>"$HOME/code/Spark-Hermes/runlog/recover.log" 2>&1 &
        disown || true
        sleep 5
        if sandbox_ready; then info "sandbox phase: Ready"; return; fi
    fi

    local phase; phase=$(sandbox_phase)
    fail "gandalf sandbox missing or unrecoverable (phase: ${phase:-unknown}). See bringup/10-install-nemoclaw.sh."
}

# ── Layer 5: Hermes Agent gateway (inside sandbox, port 8642) ───────────────

ensure_hermes_gateway() {
    echo ""; echo "=== Hermes Agent gateway (127.0.0.1:8642 → sandbox) ==="

    if hermes_gateway_healthy; then
        info "Hermes gateway healthy (round-trip via LiteLLM returned 200)"
        return
    fi

    # Most common cause after a reboot: the sandbox is fine and `hermes gateway
    # run` is still alive inside it, but the host-side port forward points at a
    # pre-reboot PID and shows as "dead". Re-establishing the forward is far
    # cheaper (and less risky) than a full recover, so try that first.
    if openshell forward list 2>/dev/null | grep -q '8642.*dead'; then
        warn "port forward 8642 is dead — restarting it"
        openshell forward stop 8642 gandalf >/dev/null 2>&1 || true
        openshell forward start -d 8642 gandalf >/dev/null 2>&1 || true
        if wait_for "port forward reconnecting" 30 hermes_gateway_healthy; then
            echo ""; info "Hermes gateway ready (port forward restored)"; return
        fi
        echo ""
    fi

    # Common cause: forward died but sandbox is fine. nemohermes recover fixes it.
    warn "gateway not responding — running nemohermes gandalf recover"
    nohup nemohermes gandalf recover >>"$HOME/code/Spark-Hermes/runlog/recover.log" 2>&1 &
    disown || true
    sleep 5

    if wait_for "Hermes gateway warming up" 60 hermes_gateway_healthy; then
        echo ""; info "Hermes gateway ready"
    else
        echo ""
        echo "Last 20 lines of Hermes gateway log:"
        local container
        container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^openshell-gandalf-' | head -1)
        if [ -n "$container" ]; then
            docker exec -u sandbox "$container" tail -20 /sandbox/.hermes/logs/gateway.log 2>&1 || true
        fi
        fail "Hermes gateway did not become healthy within 60s"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

ensure_argo_shim
ensure_vllm_reachable
ensure_bridges
ensure_litellm
ensure_sandbox
ensure_hermes_gateway

echo ""; echo "=== All Spark-Hermes services healthy ==="
info "argo-shim:        running (127.0.0.1:44497, Argo SSH tunnel up)"
info "vLLM:             reachable (shared with OpenClaw)"
info "vLLM bridges:     127.0.0.1:8000 + 172.19.0.1:8000"
info "argo bridge:      172.19.0.1:44497 → argo-shim"
info "LiteLLM:          127.0.0.1:4000 + 172.19.0.1:4000 (Claude+vLLM routing)"
info "Gandalf sandbox:  Ready"
info "Hermes gateway:   http://127.0.0.1:8642/v1 (model: claudeopus47 via LiteLLM)"
echo ""
note "Inspect any layer:"
note "  argo-shim log:    tail -F ~/code/spark-ai/argo-shim.log"
note "  LiteLLM log:      tail -F ~/code/Spark-Hermes/runlog/litellm.log"
note "  Hermes gateway:   nemohermes gandalf logs --follow"
note "  Full status:      bash ~/code/Spark-Hermes/ops/status.sh"
