#!/usr/bin/env bash
# Assert that every agent is contained and reachable THE SAME WAY, regardless of
# which runtime it uses (Hermes or OpenClaw).
#
#   bash ops/check-parity.sh          # all agents
#   bash ops/check-parity.sh gandalf  # one agent
#
# Read-only. Runs no plane-mutating commands; safe at any time.
#
# WHY THIS EXISTS
# The point of migrating OpenClaw onto the OpenShell/NemoClaw stack is to stop
# maintaining bespoke, per-runtime containment. That goal is only real if it is
# ASSERTED — otherwise divergence is discovered during an outage instead of by a
# test. This script is that assertion.
#
# The specific failure that motivated it (2026-09-01): Gandalf's Telegram adapter
# went silent for 11 days after ops/fix-sandbox-iptables.sh (2026-08-21) added
# `-s 172.19.0.0/16 -d 10.0.4.0/22 -j DROP`. The sandboxes' only DNS upstream is
# 10.0.4.1 — inside that range — so the LAN containment rule also severed DNS.
# Nothing caught it: ops/status.sh probes Slack from the HOST, which stays green
# while every in-sandbox adapter is cut off.
#
# THE TWO LAYERS (both apply to every agent; do not conflate them)
#   inner jail   OpenShell netns, 10.200.0.x. Contains the AGENT PROCESS. Has NO
#                resolver and no direct route out; everything goes through the L7
#                proxy at 10.200.0.1:3128.
#   container    Docker netns, 172.19.0.x, DOCKER-USER iptables rules. PID 1
#                (openshell-sandbox) runs the L7 proxy HERE and resolves DNS on
#                the agent's behalf.
#
# So each check must target the layer that actually owns the thing being tested:
# jail membership in the jail, DNS at the proxy layer. Probing DNS inside the jail
# always fails and proves nothing — that mistake sent the first fix at this bug to
# the wrong layer and produced a false green.

set -u

AGENTS="${1:-gandalf cecat luoji}"
PROXY_NET="10.200.0"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; RST=$'\033[0m'
info() { printf '  %s[✓]%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '  %s[!]%s %s\n' "$YLW" "$RST" "$1"; }
fail() { printf '  %s[✗]%s %s\n' "$RED" "$RST" "$1"; }
note() { printf '  %s[i]%s %s\n' "$CYN" "$RST" "$1"; }

FAILED=0

container_for() { docker ps --format '{{.Names}}' | grep -E "^openshell-(default--)?$1-" | head -1; }

# The agent process, whichever runtime: Hermes gateway or OpenClaw gateway.
agent_pid() { # agent_pid <container>
    # Scan /proc directly. `pgrep -x openclaw-gateway` never matches: the kernel
    # truncates comm to 15 chars ("openclaw-gatewa"). And `pgrep -f` matches its
    # OWN pattern argument, returning a PID that exits before nsenter runs.
    # Require a readable netns: short-lived helpers (npm/openclaw CLI calls) can
    # match on comm and then exit before nsenter runs, which previously reported
    # a healthy agent as "NO INNER JAIL". Long-lived gateways always have one.
    docker exec -u root "$1" sh -c '
        for d in /proc/[0-9]*; do
            p=${d#/proc/}
            c=$(cat "$d/comm" 2>/dev/null) || continue
            case "$c" in
                openclaw-gatewa*) ;;
                hermes*) ;;
                *) continue ;;
            esac
            tr "\0" " " < "$d/cmdline" 2>/dev/null | grep -qE "hermes gateway run|openclaw-gateway" || continue
            [ -r "$d/ns/net" ] && readlink "$d/ns/net" >/dev/null 2>&1 && echo "$p"
        done
    ' 2>/dev/null | head -1 | tr -d '[:space:]'
}

# Run a command INSIDE the agent's network namespace — the layer that matters.
in_jail() { # in_jail <container> <pid> <sh-command>
    docker exec -u root "$1" nsenter -t "$2" -n sh -c "$3" 2>&1
}

for a in $AGENTS; do
    echo ""; echo "=== $a ==="
    CON=$(container_for "$a")
    if [ -z "$CON" ]; then fail "no running container"; FAILED=$((FAILED+1)); continue; fi
    note "container: $CON"

    PID=$(agent_pid "$CON")
    if [ -z "$PID" ]; then fail "no agent process (hermes/openclaw gateway) running"; FAILED=$((FAILED+1)); continue; fi

    RUNTIME=$(docker exec -u root "$CON" sh -c "tr '\0' ' ' < /proc/$PID/cmdline" 2>/dev/null | grep -qi hermes && echo Hermes || echo OpenClaw)
    note "agent: pid $PID ($RUNTIME)"

    # 1. Inner jail exists — agent netns MUST differ from the container's.
    NS1=$(docker exec -u root "$CON" readlink /proc/1/ns/net 2>/dev/null)
    NSA=$(docker exec -u root "$CON" readlink "/proc/$PID/ns/net" 2>/dev/null)
    if [ -n "$NSA" ] && [ "$NSA" != "$NS1" ]; then
        info "inner jail: agent in own netns ($NSA != $NS1)"
    else
        fail "NO INNER JAIL — agent shares the container netns ($NSA). Containment parity broken."
        FAILED=$((FAILED+1))
    fi

    # 2. Jail is wired to the L7 proxy subnet.
    if in_jail "$CON" "$PID" "ip -brief addr" | grep -q "$PROXY_NET"; then
        info "jail network: on $PROXY_NET.0/24 (L7 proxy path)"
    else
        fail "jail not on $PROXY_NET.0/24 — egress does not go through the L7 proxy"
        FAILED=$((FAILED+1))
    fi

    # 3. DNS where it actually happens: the CONTAINER netns, where PID 1
    #    (openshell-sandbox) runs the L7 proxy and resolves on the agent's behalf.
    #    The jail deliberately has NO resolver of its own — probing DNS inside the
    #    jail always fails and says nothing about health. This is the check the
    #    11-day Telegram outage needed: a HOST-side probe (what ops/status.sh
    #    does) passes while this fails.
    if docker exec -u root "$CON" getent hosts api.telegram.org >/dev/null 2>&1; then
        info "DNS at proxy layer: resolves"
    else
        fail "DNS FAILS AT PROXY LAYER — every adapter is cut off from platform APIs"
        FAILED=$((FAILED+1))
    fi

    # 4. Ground truth: is the agent's traffic actually being ALLOWED right now?
    #    Reads the proxy's own OCSF decisions rather than synthesising a request —
    #    a curl via docker exec is rejected as an unrecognised peer (403) even
    #    when the agent itself is fine, so a synthetic probe gives false alarms.
    #    NOTE: `docker logs --since` is unreliable here (these logs carry their
    #    own UTC timestamps and the daemon's view can disagree), so scan a fixed
    #    tail instead of a time window.
    RECENT=$(docker logs --tail 400 "$CON" 2>&1 | grep -c 'OCSF.*ALLOWED' || true)
    if [ "${RECENT:-0}" -gt 0 ]; then
        info "proxy egress: $RECENT ALLOWED decision(s) in recent log"
    else
        warn "no ALLOWED egress in recent log — agent may be idle, or its adapters are not polling"
    fi

    # 5. Container-layer backstop. Informational: a missing rule is a real gap,
    #    but reading it needs root, so never fail the run on inability to check.
    SUB=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' "$CON" 2>/dev/null)
    note "container addr: ${SUB:-unknown} (DOCKER-USER rules apply here, NOT to the jail)"
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    printf '%s[✓]%s parity holds across: %s\n' "$GRN" "$RST" "$AGENTS"
else
    printf '%s[✗]%s %d parity check(s) failed — agents are NOT contained/reachable alike\n' "$RED" "$RST" "$FAILED"
    exit 1
fi
