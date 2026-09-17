#!/usr/bin/env bash
# push-pause-sentinels.sh — the OPENCLAW HALF of the three-agent kill switch.
#
#   bash ops/push-pause-sentinels.sh            # sync current pause state
#   bash ops/push-pause-sentinels.sh --check    # report only, change nothing
#
# SCOPE: cecat and luoji only. Gandalf is paused by a different mechanism on a
# different plane (native `hermes cron pause`, via ops/push-pause-gandalf.sh).
# This script is one of two halves, not the whole switch — see "HOW THIS GETS
# CALLED" at the bottom.
#
# THE BUG THIS FIXES (found 2026-09-03)
#
# `shared/scripts/ops/pause.sh` drops a sentinel in the HOST directory
# shared/state/. Both agents check for it as Step 0 of their heartbeat:
#
#     exec: ls /shared/state/PAUSE.global /shared/state/PAUSE.agent.cecat
#
# The sentinel was not reaching them, so the check ran, found nothing, and the
# agent proceeded **exactly as if no pause were set**. It fails OPEN, silently.
# An operator typing `pause.sh global` believes the agents are stopped. They
# are not.
#
# WHERE THE SENTINEL GOES, AND WHY IT MOVED (corrected 2026-09-07)
#
# This script originally targeted /sandbox/.openclaw/workspace/state, chosen
# because the workspace is a declared state dir and survives a rebuild. That
# was the wrong destination twice over: the directory does not exist in either
# sandbox, and the heartbeats never read it. Both agents' live HEARTBEAT.md
# still checks `/shared/state/...` — so the sentinel landed somewhere nothing
# looks, and the kill switch stayed fail-open.
#
# `/shared` is no longer a dead legacy path: ops/mount-agent-filespaces.sh
# symlinks it to /sandbox/shared inside each sandbox, and /sandbox/shared/state
# exists and is populated on both agents. That is the directory the heartbeat's
# `ls` actually resolves, so that is where the sentinel belongs.
#
# TRADEOFF: /sandbox/shared lives in the writable layer, NOT in a declared
# state dir, so a rebuild loses the sentinel — and so does a reboot, which
# drops the sshfs mount and the symlink with it. A pause must therefore be
# re-pushed after any rebuild or reboot. Re-run this script from
# ops/post-rebuild.sh and after ops/mount-agent-filespaces.sh --mount.
#
# The host directory stays the source of truth. This script mirrors it inward.
set -u

CHECK=false
[ "${1:-}" = "--check" ] && CHECK=true

STATE="$HOME/code/Spark-OpenClaw/shared/state"
DEST_DIR=/sandbox/shared/state

echo "════════════════════════════════════════════"
echo "  Pause sentinels -> OpenShell agents"
echo "════════════════════════════════════════════"
echo "  host source: $STATE"
echo "  sandbox dest: $DEST_DIR"
echo

# Global pause applies to everyone; the per-agent one only to its owner.
GLOBAL=""
[ -f "$STATE/PAUSE.global" ] && GLOBAL="PAUSE.global"

for AGENT in cecat luoji; do
    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    if [ -z "$CON" ]; then
        echo "  $AGENT: NO RUNNING SANDBOX — skipped"
        continue
    fi

    WANT=""
    [ -n "$GLOBAL" ] && WANT="$WANT PAUSE.global"
    [ -f "$STATE/PAUSE.agent.$AGENT" ] && WANT="$WANT PAUSE.agent.$AGENT"

    if $CHECK; then
        # Filter to PAUSE.* — the state dir holds ~15 unrelated runbook files,
        # and listing them all would read as "sentinels present".
        HAVE=$(docker exec -u sandbox "$CON" sh -c "ls $DEST_DIR 2>/dev/null | grep '^PAUSE\.' | tr '\n' ' '" 2>/dev/null || true)
        printf "  %-6s host wants:[%s ]  sandbox has:[ %s]\n" \
            "$AGENT" "${WANT:- none}" "${HAVE:-none }"
        continue
    fi

    docker exec -u sandbox "$CON" mkdir -p "$DEST_DIR" 2>/dev/null

    # Clear stale sentinels first, so an unpause on the host actually
    # propagates. Scoped to PAUSE.* inside the state dir — nothing else.
    docker exec -u sandbox "$CON" sh -c "rm -f $DEST_DIR/PAUSE.* 2>/dev/null" || true

    if [ -z "$WANT" ]; then
        echo "  $AGENT: not paused (sandbox sentinels cleared)"
        continue
    fi

    for f in $WANT; do
        # Pass the reason text through stdin rather than argv — it is
        # operator-written and may contain anything.
        docker exec -u sandbox -i "$CON" sh -c "cat > $DEST_DIR/$f" < "$STATE/$f"
        echo "  $AGENT: PAUSED -> $DEST_DIR/$f"
    done
done

cat <<'EOM'

════════════════════════════════════════════
  HOW THIS GETS CALLED
════════════════════════════════════════════
  You normally do NOT run this directly. It is one of two plane-specific
  halves, both driven by the landlord propagator in the neutral ops repo:

      spark-ops/ops/pause-propagate.sh      <- the entry point
        |-- Spark-Hermes/ops/push-pause-sentinels.sh   (this file: cecat, luoji)
        `-- Spark-Hermes/ops/push-pause-gandalf.sh     (gandalf, via hermes cron)

  pause.sh / unpause.sh call the propagator themselves, so the normal operator
  command reaches all three agents in one step:

      bash ~/code/Spark-OpenClaw/shared/scripts/ops/pause.sh global --reason "..."

  That does mean pause.sh now depends on docker being healthy. The dependency
  degrades rather than breaks: the host sentinel is written regardless, and if
  propagation fails pause.sh says so loudly and exits non-zero.

  BY HAND — still supported, as a fallback when the propagator or the other
  plane is unavailable, and after any event that drops the sandbox sentinels
  (rebuild, reboot; see the TRADEOFF note above):

      bash ~/code/Spark-Hermes/ops/push-pause-sentinels.sh

  To answer "did the pause actually take?" across all three agents:

      bash ~/code/spark-ops/ops/pause-propagate.sh --check

  NOTE: the HOST half of the kill switch works independently of all of this.
  All four cron senders (send-email, send-slack, check-todos, email-precheck)
  honour the host sentinel directly, so outbound email and Slack stop
  correctly even if no propagation happens. What this file fixes is the
  agents' own Step 0 check.
EOM
