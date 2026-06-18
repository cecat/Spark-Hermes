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

# Ensure CLIs on PATH
case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

# systemd-user env (so this works from any shell, not just login shells)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# Tracking flags so a lower-layer restart can cascade upward
ARGO_RESTARTED=false
VLLM_BRIDGES_RESTARTED=false
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
        -X POST "http://127.0.0.1:44497/v1/messages" \
        -H "Content-Type: application/json" \
        -d '{"model":"claudehaiku45","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

# Real model-list call against vLLM through the host-side socat at 127.0.0.1:8000.
vllm_healthy() {
    curl -sf --max-time 5 "http://127.0.0.1:8000/v1/models" >/dev/null 2>&1
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

# Sandbox container exists and reports Ready.
sandbox_ready() {
    local phase
    phase=$(openshell sandbox list 2>/dev/null | awk '/^gandalf/ {print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
    [ "$phase" = "Ready" ]
}

# Hermes Agent gateway returns a model list AND a real chat round-trip works.
hermes_gateway_healthy() {
    curl -sf --max-time 5 "http://127.0.0.1:8642/v1/models" >/dev/null 2>&1 || return 1
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
        -X POST "http://127.0.0.1:8642/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model":"hermes-agent","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

# ── Layer 0: argo-shim (SSH tunnel to Argonne) ──────────────────────────────

ensure_argo_shim() {
    echo ""; echo "=== argo-shim (127.0.0.1:44497) ==="

    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:44497 " && argo_shim_healthy; then
        info "argo-shim healthy (Argo round-trip returns 200)"
        return
    fi

    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:44497 "; then
        warn "argo-shim listening but failing health check — restarting"
        pkill -f "argo-shim --port 44497" 2>/dev/null || true
        sleep 1
    fi

    command -v argo-shim >/dev/null 2>&1 || fail "argo-shim not on PATH"

    warn "Starting argo-shim... (Duo may prompt on this terminal)"
    nohup argo-shim --port 44497 --no-auth >> "$HOME/code/spark-ai/argo-shim.log" 2>&1 &
    disown || true

    # Quiet window: ssh tunnel cold-start prompts for Duo on the TTY.
    echo "    ↳ If Duo prompts on this terminal, enter your passcode now."
    echo "      (waiting 20s before health-check progress starts)"
    sleep 20

    if wait_for "argo-shim warming up (incl. SSH tunnel)" 90 argo_shim_healthy; then
        echo ""; info "argo-shim ready"
        ARGO_RESTARTED=true
    else
        echo ""
        echo "Last 20 lines of $HOME/code/spark-ai/argo-shim.log:"
        tail -20 "$HOME/code/spark-ai/argo-shim.log" 2>&1 || true
        fail "argo-shim did not become healthy within 90s"
    fi
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
    if ! ensure_bridge_unit gandalf-vllm-bridge.service "127.0.0.1:8000 → vLLM"; then
        VLLM_BRIDGES_RESTARTED=true
    fi
    if ! ensure_bridge_unit gandalf-vllm-bridge-openshell.service "172.19.0.1:8000 → vLLM"; then
        VLLM_BRIDGES_RESTARTED=true
    fi

    # Argo bridge — needed because LiteLLM is on host but argo-shim is also on host;
    # this one isn't strictly required for LiteLLM (talks to 127.0.0.1:44497 directly)
    # but it's harmless and useful if anything inside the sandbox ever wants direct shim access.
    ensure_bridge_unit gandalf-argo-bridge.service "172.19.0.1:44497 → argo-shim"
}

# ── Layer 3: LiteLLM proxy ──────────────────────────────────────────────────

ensure_litellm() {
    echo ""; echo "=== LiteLLM proxy (127.0.0.1:4000) ==="

    if systemctl --user is-active gandalf-litellm.service >/dev/null 2>&1 && litellm_healthy; then
        info "LiteLLM healthy (Claude round-trip returns 200)"
    else
        if systemctl --user is-active gandalf-litellm.service >/dev/null 2>&1; then
            warn "LiteLLM active but health failed — restarting"
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

    if sandbox_ready; then
        info "sandbox phase: Ready"
        return
    fi

    # Sandbox exists but not Ready — try recover (gateway restart). If it
    # doesn't exist at all, that's a bringup issue, not a daily-restore issue.
    if openshell sandbox list 2>/dev/null | grep -q '^gandalf'; then
        warn "sandbox exists but not Ready — running nemohermes gandalf recover"
        nemohermes gandalf recover 2>&1 | head -5 || true
        sleep 5
        if sandbox_ready; then info "sandbox phase: Ready"; return; fi
    fi

    fail "gandalf sandbox missing or unrecoverable. See bringup/10-install-nemoclaw.sh."
}

# ── Layer 5: Hermes Agent gateway (inside sandbox, port 8642) ───────────────

ensure_hermes_gateway() {
    echo ""; echo "=== Hermes Agent gateway (127.0.0.1:8642 → sandbox) ==="

    if hermes_gateway_healthy; then
        info "Hermes gateway healthy (round-trip via LiteLLM returned 200)"
        return
    fi

    # Common cause: forward died but sandbox is fine. nemohermes recover fixes it.
    warn "gateway not responding — running nemohermes gandalf recover"
    nemohermes gandalf recover 2>&1 | head -5 || true
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
