#!/usr/bin/env bash
# restart-openclaw-gateways.sh — restart the in-sandbox OpenClaw gateway for
# cecat and/or luoji so a config change takes effect.
#
#   bash ops/restart-openclaw-gateways.sh                  # both agents
#   bash ops/restart-openclaw-gateways.sh cecat            # one agent
#
# The gateway reads openclaw.json at start. Config edits (heartbeat, compaction,
# channels) do nothing until the process is restarted.
#
# ── WHY THIS EXISTS RATHER THAN `ops/apply-heartbeat.sh` ────────────────────
#
# apply-heartbeat.sh also restarts the gateway, but it PATCHES CONFIG FIRST —
# and at line 113-114 it runs:
#
#     for a in d.get("agents", {}).get("list", []):
#         a.pop("heartbeat", None)
#
# i.e. it DELETES the per-agent heartbeat block, which is exactly where
# `isolatedSession: true` lives (and where this build actually reads the
# heartbeat from — see PUNCHLIST P-DEADPATHS / decision-log: `agents.list` is
# correct for openclaw 2026.7.1; the docs describing `agents.defaults` refer to
# a later release). **Running it after apply-isolated-heartbeat.sh would
# silently undo that fix.** This script only restarts. It touches no config.
#
# ── MECHANISM ───────────────────────────────────────────────────────────────
#
# SIGTERM to the gateway process inside the sandbox; the container's supervisor
# respawns it. This is the same mechanism apply-heartbeat.sh uses, extracted.
# The container is NOT restarted, so C-4 (never recreate a sandbox) is not
# engaged and the writable layer — mounts, symlinks, OOM patch — is untouched.
#
# Brief downtime is fine: no agent is production (GOALS.md).
set -uo pipefail

WANT="${1:-all}"
case "$WANT" in
    all|cecat|luoji) ;;
    *) echo "Usage: $0 [cecat|luoji]   (default: both)" >&2; exit 1 ;;
esac

RC=0

for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    [ "$WANT" = all ] || [ "$WANT" = "$AGENT" ] || continue

    CON="$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)"
    if [ -z "$CON" ]; then
        echo "FAIL: no running sandbox container for $AGENT"; RC=1; continue
    fi

    echo "════════════════════════════════════════════"
    echo "  $AGENT (plane $PORT)"
    echo "  container: $CON"
    echo "════════════════════════════════════════════"

    BEFORE="$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null || true)"
    echo "  pid before: ${BEFORE:-none}"

    docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' 2>/dev/null || true
    sleep 8

    AFTER="$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null || true)"
    if [ -z "$AFTER" ]; then
        echo "  pid after:  NONE — gateway did NOT come back"
        echo "  >>> investigate before restarting the other agent <<<"
        RC=1; continue
    fi
    if [ "$AFTER" = "$BEFORE" ]; then
        echo "  pid after:  $AFTER — UNCHANGED, the restart did not take"
        RC=1; continue
    fi
    echo "  pid after:  $AFTER — restarted"
done

if [ "$RC" -eq 0 ]; then
    cat <<'EOF'

  VERIFY the config actually took effect — a new pid alone proves nothing:

    # 1. heartbeat is ticking again (wait up to 15 min)
    tail -5 ~/.nemoclaw/gateways/8090/mounts/cecat/.openclaw/logs/gateway-persistent.log

    # 2. THE REAL TEST for isolatedSession: token count stops climbing
    bash ops/reset-sessions-openshell.sh --check
    #    maxTokens should flatten across ticks instead of growing

    # 3. THE REAL TEST that instructions still reach her: a READY item in
    #    /workspace/TODO.md flips to COMPLETED. A heartbeat that wakes with no
    #    context looks IDENTICAL to a healthy one in the log.
EOF
fi

exit "$RC"
