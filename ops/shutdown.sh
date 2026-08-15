#!/usr/bin/env bash
set -uo pipefail
#
# ════════════════════════════════════════════════════════════════════════════
#  Graceful shutdown for the Spark-Hermes / Gandalf layer — run before reboot.
# ════════════════════════════════════════════════════════════════════════════
#
# The inverse of ops/start-all.sh, and the mirror image of it in scope: this
# script owns exactly the layer that script starts — the GANDALF tenant.
#
# PREFER ~/shutdown.sh. That is the host-wide orchestrator (DGX-Spark), which
# calls this script, then spark-ai's, then stops the shared substrate in the
# right order. Running this one alone is correct but partial.
#
# Usage:
#   bash ops/shutdown.sh            stop the Gandalf layer, in dependency order
#   bash ops/shutdown.sh --check    report what WOULD be stopped; change nothing
#
# ── Scope: one tenant, not the whole memory layer ───────────────────────────
#
# FALDA / Sibline / Ollama / UMP are multi-tenant and shared with OpenClaw.
# They split three ways, and this script stops ONLY the first group:
#
#   gandalf tenant  falda-tap-gandalf, falda-distiller-gandalf,
#     (here)        gandalf-sibline-shuttle
#   luoji tenant    falda-tap-luoji, falda-distiller-luoji,
#                   sibline-bridge-luoji        → spark-ai/shutdown.sh
#   shared          falda-gateway, ump-memory, falda-ump-mirror, ollama,
#     substrate     sibline-broker              → DGX-Spark/ops/shutdown.sh
#
# An earlier draft stopped all three groups from here. It was safe (every tap
# and distiller checkpoints atomically and only after successful work, so the
# worst case is lag, never loss) but it meant one repo's script reached into two
# others, and left start/stop asymmetric: ~/start-all.sh treats the shared
# substrate as "Layer 5 — verify only" and starts none of it.
#
# ── What this does NOT stop, and why ────────────────────────────────────────
#
#   argo-shim, vLLM, openclaw-gateway   spark-ai/shutdown.sh owns these. vLLM is
#                                       shared, so stopping it here would kill
#                                       OpenClaw out from under its own script.
#   falda-gateway, ollama, and the      Shared substrate — see the table above.
#   rest of the Sibline/UMP layer       Leaving them up is harmless: the gandalf
#                                       writers are already stopped, and the
#                                       luoji ones still need them.
#
# ── Ordering rationale (this is the whole point of the script) ──────────────
#
# Reverse dependency order alone isn't enough — two consumers read the sandbox
# through `docker exec`, so they must be quiesced while the container is still
# alive or their in-flight work is lost, not merely interrupted:
#
#   falda-tap-gandalf   reads /sandbox/.hermes/runtime/state.db and checkpoints
#                       on messages.id. Stop the container first and the tap
#                       can no longer read the turns it hasn't mirrored yet.
#                       Phase 2 waits for its checkpoint to catch up instead.
#   gandalf-sibline-shuttle  moves the host mailbox into the sandbox by exec.
#                            Stopped first (phase 1) so it isn't mid-copy.
#
# Everything stopped here is a systemd user unit with WantedBy=default.target
# and linger enabled, so `systemctl --user stop` is not `disable` — they all
# come back on their own at next boot. Only the sandbox container needs help
# (see phase 4).
#
# ── Shutdown method per component (each checked against its upstream) ───────
#
# `systemctl --user stop` sends SIGTERM (KillSignal=15, KillMode=control-group,
# TimeoutStopSec=90s) on every unit here. That is only "graceful" if the program
# actually handles SIGTERM, so this was verified per component rather than
# assumed — the Hermes gateway is a real counterexample (see phase 4).
#
#   Hermes gateway  `hermes gateway stop` — upstream CLI, targets gateway.pid.
#                   REQUIRED: docker stop alone does NOT reach it (phase 4).
#   FALDA writers   Python loops with no SIGTERM handler, so systemd's SIGTERM
#   (tap/distiller) raises KeyboardInterrupt/kills them between iterations. Safe
#                   because both checkpoint atomically (tmp + os.replace) and
#                   only AFTER a successful write — falda_distiller.py:210,
#                   falda_tap_hermes.py:204. An interrupted pass is re-done at
#                   next boot; it is never half-recorded.
#   LiteLLM         uvicorn handles SIGTERM with its own graceful drain.
#   socat bridges   Stateless byte-forwarders; SIGTERM is all there is.
#   OpenShell       `openshell forward stop` for the :8642 forward (documented
#                   verb). The :8080 daemon takes SIGTERM, which it DOES handle
#                   (SigCgt includes it) — see phase 8.

export PATH="$HOME/.local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[…]${NC} %s\n" "$*"; }
bad()  { printf "${RED}[✗]${NC} %s\n" "$*"; }
note() { printf "${CYAN}[i]${NC} %s\n" "$*"; }
hdr()  { printf "\n${BOLD}=== %s ===${NC}\n" "$*"; }

CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        *) bad "Unrecognized argument: $arg"; note "Usage: $0 [--check]"; exit 1 ;;
    esac
done

PROBLEMS=()

# How long phase 2 waits for the FALDA tap to catch up. The tap polls on a 20s
# timer (TAP_POLL), so anything under ~25s can expire before it looks even once.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-30}"

TAP_STATE="${TAP_STATE:-$HOME/.falda/tap_state_gandalf.json}"

CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^openshell-gandalf-' | head -1)

# stop_unit <unit> <description>
# Reports and continues on failure — one stuck unit must not strand the rest.
stop_unit() {
    local unit=$1 desc=$2
    if ! systemctl --user is-active "$unit" >/dev/null 2>&1; then
        info "$unit already stopped"
        return 0
    fi
    if $CHECK_ONLY; then
        note "would stop $unit ($desc)"
        return 0
    fi
    warn "stopping $unit ($desc)"
    if systemctl --user stop "$unit" 2>/dev/null; then
        info "$unit stopped"
    else
        bad "failed to stop $unit"
        PROBLEMS+=("$unit")
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 0 — pre-flight: will this host actually come back up?
# ════════════════════════════════════════════════════════════════════════════
# Stopping the sandbox cleanly is the one irreversible-ish thing here. Its
# restart policy is unless-stopped, and Docker deliberately SKIPS containers
# that were cleanly stopped — so after this script runs, Docker will NOT bring
# the sandbox back at boot. gandalf-boot-recover.service is what does, via
# `docker start`. If that unit is disabled or disarmed, Gandalf stays down
# after the reboot until someone runs ~/start-all.sh by hand. Say so now,
# while it's still cheap to fix, rather than discovering it tomorrow.

phase_preflight() {
    hdr "Phase 0: pre-flight — reboot recovery readiness"

    # 'enabled' only means systemd will RUN the unit, not that it will succeed.
    # Report both facts as one verdict rather than two lines that contradict
    # each other ("armed, will restart at boot" directly above "failed").
    local recover_failed=false
    [ "$(systemctl --user is-failed gandalf-boot-recover.service 2>/dev/null)" = "failed" ] && recover_failed=true

    if [ -f "$HOME/.no-autostart" ]; then
        warn "~/.no-autostart exists — gandalf-boot-recover.service will SKIP itself at boot"
        note "Gandalf will stay down until you run ~/start-all.sh. Re-arm with: rm ~/.no-autostart"
    elif ! systemctl --user is-enabled gandalf-boot-recover.service >/dev/null 2>&1; then
        warn "gandalf-boot-recover.service is NOT enabled"
        note "Nothing will 'docker start' the sandbox at boot; plan to run ~/start-all.sh"
    elif $recover_failed; then
        warn "gandalf-boot-recover.service is enabled but FAILED at the last boot"
        note "It is armed, but it did not work last time — don't assume the sandbox comes back."
        note "Check first:  systemctl --user status gandalf-boot-recover.service"
        note "Boot log:     ~/start-all-boot.log     Fallback: ~/start-all.sh"
    else
        info "gandalf-boot-recover.service enabled and healthy — sandbox will restart at boot"
    fi

    if [ -z "$CONTAINER" ]; then
        note "no running gandalf sandbox container — phases 1–4 will mostly no-op"
    else
        info "sandbox container: $CONTAINER"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — quiesce the sandbox-side shuttle
# ════════════════════════════════════════════════════════════════════════════
# The Sibline shuttle copies the host staging mailbox into
# /sandbox/.hermes/sibline via docker exec. Stopping it before the container
# means it can't be halfway through a copy when the container disappears. Its
# host-side feeder (sibline-bridge-gandalf) keeps running until phase 6, so
# anything that arrives in the meantime just waits in the host mailbox.

phase_shuttle() {
    hdr "Phase 1: Sibline shuttle (sandbox-side writer)"
    stop_unit gandalf-sibline-shuttle.service "host mailbox → sandbox"
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — drain the FALDA tap while state.db is still reachable
# ════════════════════════════════════════════════════════════════════════════
# The tap mirrors Hermes conversation turns into FALDA's stream tier and
# checkpoints on the monotonic messages.id PK (~/.falda/tap_state_gandalf.json).
# Wait for that checkpoint to reach the highest id the tap would ever consider,
# using the SAME filter the tap uses — a different filter would name a target
# the checkpoint can never reach, and we'd burn the full timeout every run.
#
# Not fatal if it doesn't converge: the checkpoint only advances over turns
# that were actually accepted, so the tap re-sends the remainder at next boot.
# The wait just means it happens now, with FALDA up, instead of later.

# Values are bound as parameters rather than inlined: this SQL is embedded in a
# single-quoted shell string, so string literals would have to be double-quoted,
# and double quotes in SQLite mean *identifier* — it only falls back to a string
# literal as a legacy misfeature that a SQLITE_DQS build disables. Parameters
# sidestep that entirely.
max_message_id() {
    [ -n "$CONTAINER" ] || return 1
    docker exec -u sandbox "$CONTAINER" python3 -c '
import sqlite3
con = sqlite3.connect("file:/sandbox/.hermes/runtime/state.db?mode=ro", uri=True)
row = con.execute("""
SELECT COALESCE(MAX(m.id), 0)
FROM messages m JOIN sessions s ON m.session_id = s.id
WHERE s.source IN (?, ?)
  AND m.role IN (?, ?)
  AND m.content IS NOT NULL AND length(trim(m.content)) > 0
""", ("telegram", "slack", "user", "assistant")).fetchone()
print(row[0])
' 2>/dev/null
}

tap_checkpoint() {
    python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("last_id", 0))
except Exception:
    print(0)
' "$TAP_STATE" 2>/dev/null
}

phase_drain() {
    hdr "Phase 2: drain FALDA tap (Hermes state.db → :8077)"

    if [ -z "$CONTAINER" ]; then
        note "sandbox not running — nothing to drain"
        return 0
    fi
    if ! systemctl --user is-active falda-tap-gandalf.service >/dev/null 2>&1; then
        note "falda-tap-gandalf not running — nothing to drain"
        return 0
    fi

    local target; target=$(max_message_id)
    if [ -z "$target" ]; then
        warn "could not read state.db — skipping drain"
        return 0
    fi

    local cursor; cursor=$(tap_checkpoint)
    if [ "$cursor" -ge "$target" ] 2>/dev/null; then
        info "tap already caught up (checkpoint $cursor / $target)"
        return 0
    fi

    if $CHECK_ONLY; then
        note "would wait up to ${DRAIN_TIMEOUT}s for tap to mirror $((target - cursor)) turn(s)"
        return 0
    fi

    warn "tap is $((target - cursor)) turn(s) behind — waiting up to ${DRAIN_TIMEOUT}s"
    local elapsed=0
    while [ "$elapsed" -lt "$DRAIN_TIMEOUT" ]; do
        sleep 2; elapsed=$((elapsed + 2))
        cursor=$(tap_checkpoint)
        if [ "$cursor" -ge "$target" ] 2>/dev/null; then
            printf "\r"; info "tap drained (checkpoint $cursor / $target, ${elapsed}s)"
            return 0
        fi
        printf "\r${YELLOW}[…]${NC} draining tap — %s/%s, %ds/%ds..." "$cursor" "$target" "$elapsed" "$DRAIN_TIMEOUT"
    done
    echo ""
    warn "tap still behind at $cursor / $target — stopping anyway"
    note "Not data loss: the checkpoint only advances over accepted turns, so the tap re-sends the rest at next boot."
    note "If this happens every run, check FALDA: curl -s 127.0.0.1:8077/healthz  and  tail ~/.falda/tap_gandalf.log"
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 3 — Gandalf's FALDA writers
# ════════════════════════════════════════════════════════════════════════════
# The two processes that read Gandalf's conversation history and POST it into
# FALDA. Stopped now, after the phase 2 drain, so neither is mid-write when the
# sandbox goes away in phase 4.
#
# The gateway they write INTO (:8077) stays up — it is shared substrate, and the
# luoji tenant is still using it. ~/shutdown.sh stops it after both tenants are
# down. The luoji equivalents of these two units are spark-ai's to stop.

phase_falda_writers() {
    hdr "Phase 3: Gandalf FALDA writers"
    stop_unit falda-tap-gandalf.service       "Hermes state.db → FALDA"
    stop_unit falda-distiller-gandalf.service "T0→T3 synthesis via Argo"
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 4 — stop the Hermes gateway, then the sandbox container
# ════════════════════════════════════════════════════════════════════════════
#
# ── Why `docker stop` alone is NOT graceful here (measured, not assumed) ────
#
# The obvious implementation — just `docker stop -t 30` and trust PID 1's
# SIGTERM trap — does not work in this container, because the trap is not on
# PID 1. The process tree is:
#
#     PID 1   openshell-sandbox        (Go/ELF supervisor, root)
#     └ PID 98  bash nemoclaw-start    (sandbox user) ← has the SIGTERM trap
#       └ PID 212  hermes gateway run  (sandbox user) ← owns state.db
#
# `docker stop` signals PID 1 only. PID 1's /proc/1/status SigCgt is
# 0x100010440 = SIGBUS|SIGSEGV|SIGCHLD|SIG33 — **SIGTERM is not in it**, and a
# process with PID 1 in a namespace gets no default action for signals it has
# no handler for. So SIGTERM is discarded, the 30s timer expires, and Docker
# SIGKILLs the whole tree — exactly the ungraceful outcome we set out to avoid.
# cleanup_on_signal is real, but it is trapped by PID 98, which never sees it.
#
# So stop the gateway explicitly first, then stop the container.
#
# ── Use the CLI's own stop path, not a hand-rolled kill ─────────────────────
#
# `hermes gateway stop` → profiles.py:_stop_gateway_process() reads
# /sandbox/.hermes/gateway.pid, sends a graceful terminate, polls up to 10s,
# and only then force-kills. That is upstream's supported shutdown and it
# targets PID 212 directly, so it does not depend on the broken trap chain.
# Verified the pid file is present and accurate: {"pid": 212, ...}.
#
# Upstream note: hermes-agent issue #19153 ("Gateway shutdown can interrupt
# active session after SIGTERM/SIGINT") means even this can cut off a turn
# that is mid-flight. There is a drain-aware SIGUSR1 path (exit code 75) but
# it is designed for restart-under-a-supervisor, not shutdown — using it here
# would ask the gateway to come back up seconds before we stop the container.
# A brief wait for the gateway to go idle is the honest mitigation; phase 2's
# tap drain already ran, so nothing is lost from FALDA's side either way.
#
# Then `docker stop -t 30` to bring down the container itself.
#
# ── This phase deliberately does NOT touch the config integrity hashes ──────
#
# An earlier draft recomputed /etc/nemoclaw/hermes.config-hash here, on the
# theory (stated in CLAUDE.md) that runtime .env writes drift it out of sync and
# the next start refuses to launch. That is NOT true of this deployment, and
# recomputing would have been a pointless write to a security-relevant file:
#
#   * PID 1 steps down to the `sandbox` user before running nemoclaw-start, so
#     startup takes the NON-ROOT path (nemoclaw-start:838), which calls
#     verify_config_integrity_if_locked with no explicit hash file. That
#     defaults to /sandbox/.hermes/.config-hash — a DIFFERENT file from the
#     /etc/nemoclaw one, and the only one that actually gates startup here.
#   * That file is sandbox-owned, mode 600. The verifier treats a hash with
#     write bits as a non-anchor and SKIPS the check entirely:
#     "[config] Config integrity check skipped for mutable default".
#   * /etc/nemoclaw/hermes.config-hash is read only by the root path
#     (nemoclaw-start:889), which this container never reaches.
#
# Empirically: both files have been drifted for weeks, and this container was
# restarted cleanly today (18:09Z) with the skip message in its log. Which
# matches the operator's experience that reboots have never needed hash repair.
#
# If the deployment ever moves to the root entrypoint, that changes — but a
# shutdown script is the wrong place to discover it. Leave the files alone.

gateway_pid() {
    docker exec -u sandbox "$CONTAINER" pgrep -f 'hermes gateway run' 2>/dev/null | head -1
}

phase_sandbox() {
    hdr "Phase 4: Hermes gateway + sandbox container"

    if [ -z "$CONTAINER" ]; then
        local stopped
        stopped=$(docker ps -a --filter 'status=exited' --format '{{.Names}}' 2>/dev/null | grep '^openshell-gandalf-' | head -1)
        [ -n "$stopped" ] && info "sandbox already stopped ($stopped)" || note "no gandalf sandbox container found"
        return 0
    fi

    local gpid; gpid=$(gateway_pid)

    if $CHECK_ONLY; then
        if [ -n "$gpid" ]; then
            note "would run: hermes gateway stop (in-sandbox, targets PID $gpid via gateway.pid)"
        else
            note "gateway not running — would skip straight to the container"
        fi
        note "would run: docker stop -t 30 $CONTAINER"
        return 0
    fi

    if [ -n "$gpid" ]; then
        warn "stopping Hermes gateway (PID $gpid) so it closes state.db cleanly"
        # HOME must be set: the CLI resolves the profile dir (and gateway.pid)
        # from it, and a bare docker exec leaves HOME=/root, which this user
        # cannot read (PermissionError before the command even parses).
        docker exec -u sandbox -e HOME=/sandbox "$CONTAINER" \
            /opt/hermes/.venv/bin/python /usr/local/bin/hermes gateway stop 2>&1 \
            | sed 's/^/    /' || true

        # Trust the observed process, not the command's exit status.
        local waited=0
        while [ "$waited" -lt 15 ]; do
            [ -z "$(gateway_pid)" ] && break
            sleep 1; waited=$((waited + 1))
        done

        if [ -z "$(gateway_pid)" ]; then
            info "Hermes gateway stopped (${waited}s)"
        else
            warn "gateway still running after ${waited}s — docker stop's SIGKILL will end it"
            note "state.db is WAL-mode SQLite, so this is a crash-consistent stop, not corruption."
            PROBLEMS+=("hermes gateway did not stop cleanly")
        fi
    else
        info "Hermes gateway already stopped"
    fi

    # PID 1 does not trap SIGTERM (see the block above), so this 30s window is
    # mostly a formality — the container ends on Docker's SIGKILL. That is fine
    # now that the gateway has already exited on its own terms.
    warn "stopping sandbox container"
    if docker stop -t 30 "$CONTAINER" >/dev/null 2>&1; then
        info "sandbox container stopped"
    else
        bad "docker stop failed for $CONTAINER"
        PROBLEMS+=("sandbox container")
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 5 — Gandalf's Sibline client
# ════════════════════════════════════════════════════════════════════════════
# The host-side NATS client that feeds Gandalf's mailbox. Its sandbox-side
# counterpart (the shuttle) went down in phase 1; this is the other half.
#
# The broker itself (:4222) is shared substrate and stays up — luoji is still a
# client. JetStream persists to ~/.sibline/jetstream, so anything that arrives
# after this just waits on disk until the next boot.

phase_sibline() {
    hdr "Phase 5: Gandalf Sibline client"
    stop_unit sibline-bridge-gandalf.service "NATS → host mailbox (gandalf)"
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 6 — LiteLLM proxy and the socat bridges
# ════════════════════════════════════════════════════════════════════════════
# Stateless plumbing, stopped last because everything above routes through it.
# A reboot would kill these harmlessly; stopping them explicitly just means the
# summary reflects reality and no half-open sockets linger during shutdown.
#
# The vLLM and Argo bridges point at services this script does not own — they
# are OUR socat processes, so we stop them, but note that spark-ai/shutdown.sh
# still needs to run to take down what's on the far end.

phase_plumbing() {
    hdr "Phase 6: LiteLLM + socat bridges"
    stop_unit gandalf-litellm-bridge.service        "172.19.0.1:4000 → LiteLLM"
    stop_unit gandalf-litellm.service               "LiteLLM proxy :4000"
    stop_unit gandalf-falda-bridge-openshell.service "172.19.0.1:8077 → FALDA"
    stop_unit gandalf-vllm-bridge.service           "127.0.0.1:8000 → vLLM"
    stop_unit gandalf-vllm-bridge-openshell.service "172.19.0.1:8000 → vLLM"
    stop_unit gandalf-argo-bridge.service           "172.19.0.1:44497 → argo-shim"
}

# ════════════════════════════════════════════════════════════════════════════
#  PHASE 7 — OpenShell host processes
# ════════════════════════════════════════════════════════════════════════════
# Three OpenShell processes run on the HOST (outside the sandbox container).
# None is a systemd unit, so nothing above touches them:
#
#   openshell-gateway            the :8080 docker-driver daemon
#   openshell ssh-proxy          } the :8642 port forward into the sandbox,
#   ssh -L 127.0.0.1:8642 ...    } as a ProxyCommand pair
#
# Order matters: stop the forward first. It is a client of the daemon (it
# reaches the sandbox via --gateway http://127.0.0.1:8080), so killing the
# daemon first would strand it against a dead endpoint.
#
# The forward is already pointing at a container we stopped in phase 4, so
# `openshell forward stop` is the documented way to retire both processes
# together rather than leaving two orphaned ssh clients until reboot.
#
# The daemon DOES handle SIGTERM — /proc/<pid>/status SigCgt includes it
# (unlike the sandbox's PID 1, which is why phase 4 needs special handling).
# So a plain `kill` is its graceful path. Worth doing rather than leaving to
# reboot: it owns openshell.db, which is journal_mode=delete (NOT WAL), so it
# has no crash-recovery journal to replay — a rollback-journal database killed
# mid-write depends on the journal file surviving, and a clean exit avoids
# relying on that. `openshell` exposes no daemon-stop verb; the CLI's own
# start path is a side effect of `nemohermes gandalf status`.

OPENSHELL_STATE="${OPENSHELL_STATE:-$HOME/.local/state/nemoclaw/openshell-docker-gateway}"

phase_openshell() {
    hdr "Phase 7: OpenShell host processes"

    # 1. The :8642 port forward (ssh-proxy + its ssh client).
    if openshell forward list 2>/dev/null | grep -q 'gandalf'; then
        if $CHECK_ONLY; then
            note "would run: openshell forward stop 8642 gandalf"
        else
            warn "stopping :8642 port forward into the sandbox"
            if openshell forward stop 8642 gandalf >/dev/null 2>&1; then
                info "port forward stopped"
            else
                warn "openshell forward stop failed — the sandbox is already down, so this is cosmetic"
            fi
        fi
    else
        info "no active port forward"
    fi

    # 2. The :8080 gateway daemon.
    local pid=""
    [ -f "$OPENSHELL_STATE/openshell-gateway.pid" ] && pid=$(cat "$OPENSHELL_STATE/openshell-gateway.pid" 2>/dev/null)

    # Confirm the pid is actually the daemon: a stale pid file after a crash
    # could name a recycled, unrelated process, and this sends a real signal.
    if [ -n "$pid" ] && ! grep -qa 'openshell-gateway' "/proc/$pid/cmdline" 2>/dev/null; then
        warn "pid file names PID $pid, which is not openshell-gateway — ignoring it"
        pid=""
    fi

    if [ -z "$pid" ]; then
        info "OpenShell daemon not running"
        return 0
    fi

    if $CHECK_ONLY; then
        note "would run: kill $pid (openshell-gateway :8080 — handles SIGTERM)"
        return 0
    fi

    warn "stopping OpenShell gateway daemon (PID $pid)"
    kill "$pid" 2>/dev/null || true
    local waited=0
    while [ "$waited" -lt 10 ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1; waited=$((waited + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "daemon still running after ${waited}s — leaving it for the reboot"
        note "It handles SIGTERM, so this is unexpected: check $OPENSHELL_STATE/openshell-gateway.log"
        PROBLEMS+=("openshell daemon did not exit")
    else
        info "OpenShell daemon stopped (${waited}s)"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════════════════════

$CHECK_ONLY && note "--check: reporting only, stopping nothing"

phase_preflight
phase_shuttle
phase_drain
phase_falda_writers
phase_sandbox
phase_sibline
phase_plumbing
phase_openshell

hdr "Summary"

if $CHECK_ONLY; then
    note "--check complete — nothing was stopped"
    exit 0
fi

if [ ${#PROBLEMS[@]} -eq 0 ]; then
    info "Gandalf layer is down cleanly"
else
    bad "${#PROBLEMS[@]} problem(s): ${PROBLEMS[*]}"
fi

# Only nag about the rest of the host when run standalone. Under ~/shutdown.sh
# the orchestrator prints its own summary and is already doing all of this.
if [ -z "${SHUTDOWN_ORCHESTRATED:-}" ]; then
    echo ""
    note "Still up — NOT this script's to stop:"
    note "  spark-ai:  argo-shim :44497 │ vLLM :8000 │ openclaw-gateway │ luoji tenant"
    note "  shared:    FALDA :8077 │ Ollama :11434 │ NATS :4222 │ UMP :4100"
    note "Note: the OpenShell daemon is now down, so \`openshell\`/\`nemohermes\` commands"
    note "will fail with 'transport error' until ~/start-all.sh restarts it."
    note "Finish the shutdown with:             ~/shutdown.sh   (does all of the above)"
    note "Bring everything back after reboot:   ~/start-all.sh"
fi

[ ${#PROBLEMS[@]} -eq 0 ] || exit 1
