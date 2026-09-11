#!/usr/bin/env bash
# mount-agent-filespaces.sh — restore /workspace and /shared for the OpenClaw
# agents on OpenShell, using sshfs + in-sandbox symlinks.
#
#   bash ops/mount-agent-filespaces.sh --check     # report only (default)
#   bash ops/mount-agent-filespaces.sh --mount     # mount + create symlinks
#   bash ops/mount-agent-filespaces.sh --unmount   # tear down
#
# ── WHAT THIS FIXES ─────────────────────────────────────────────────────────
#
# The legacy gateway bind-mounted three host directories into every agent
# container: `<agent>` at /workspace, `shared` at /shared, `<agent>/scripts` at
# /scripts. Host and agent addressed the SAME INODE — no sync, no drift. That
# contract lived only in container launch arguments, appears in no config file,
# and was never migrated. 10 of 12 runbooks reference those paths, so every one
# of them has been silently inert on the new stack.
#
# ── HOW IT WORKS, AND THE ONE NON-OBVIOUS PART ──────────────────────────────
#
# `nemoclaw <agent> share mount` gives the HOST a live read-write view of the
# sandbox via sshfs. Proven bidirectional and instant on luoji 2026-09-05:
# host write -> sandbox saw it immediately; sandbox write -> host saw it.
#
# But it exposes `/sandbox`, not `/`. Host content written through the mount
# lands at `/sandbox/shared`, while the runbooks look for `/shared` at the
# filesystem root — which sshfs cannot reach. **So the mount alone is not
# enough.** Two in-sandbox symlinks bridge the gap:
#
#     /shared    -> /sandbox/shared                  (created by this script)
#     /workspace -> /sandbox/.openclaw/workspace     (content already correct;
#                                                     only the path was wrong)
#
# `/scripts` is deliberately NOT symlinked: the image ships its own /scripts
# (generate-openclaw-config.mts, lib/) and replacing it could break image
# tooling. Runbooks referencing /scripts/*.py need the two api wrappers copied
# in — see ops/fix-agent-paths.sh.
#
# ── THE PREFLIGHT BUG THIS WORKS AROUND ─────────────────────────────────────
#
# `share mount` refuses with a version-skew error unless
# NEMOCLAW_OPENSHELL_GATEWAY_STATE_DIR is set per-plane. Cause, verified in
# source: `resolveDockerDriverGatewayStateDir` (onboard/host-gateway-process.ts:122)
# falls back to a NON-port-scoped path, so a cecat command compares cecat's
# 0.0.101 CLI against GANDALF's 0.0.44 binary. The port-aware resolver exists —
# `resolveGatewayStateDirName(port)` at onboard/gateway-binding.ts:165 — and the
# drift check never calls it. Pointing the env var at the per-port state dir
# makes the check compare the CORRECT pair. **This preserves the safety check;
# it does not disable it.**
#
# The two OpenShell versions on this box are both correct: NemoClaw v0.0.55
# (Gandalf) pins 0.0.44 exactly; v0.0.108 (cecat/luoji) pins 0.0.101 exactly.
# Per-port isolation is documented as supported. Do not "fix" the split.
#
# ── NOT PERSISTENT ──────────────────────────────────────────────────────────
#
# An sshfs mount does not survive a host reboot, and the symlinks live in the
# container's writable layer, which is wiped on rebuild. Both must be
# re-established — a systemd unit for the mount, and post-rebuild.sh for the
# symlinks. Until that is wired, THIS IS A MANUAL STEP AFTER EVERY REBOOT, and
# a silent one: the agents will keep answering Slack while every runbook goes
# inert again.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) ACT=check ;; --mount) ACT=mount ;; --unmount) ACT=unmount ;;
  *) echo "Usage: $0 [--check|--mount|--unmount]" >&2; exit 1 ;;
esac

STATE_BASE="$HOME/.local/state/nemoclaw/openshell-docker-gateway"
RC=0

for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    MNT="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT"

    echo "════════════════════════════════════════════"
    echo "  $AGENT (plane $PORT)"
    echo "════════════════════════════════════════════"

    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    if [ -z "$CON" ]; then echo "  NO SANDBOX — skipped"; RC=1; continue; fi

    export NEMOCLAW_OPENSHELL_GATEWAY_STATE_DIR="${STATE_BASE}-${PORT}"

    case "$ACT" in
    check)
        printf "  sshfs mount      : "
        mountpoint -q "$MNT" 2>/dev/null && echo "MOUNTED at $MNT" || echo "not mounted"
        docker exec -u sandbox "$CON" sh -c '
          for p in /shared /workspace /sandbox/shared /sandbox/.openclaw/workspace; do
              printf "  %-17s: " "$p"
              if [ -L "$p" ]; then echo "symlink -> $(readlink $p)"
              elif [ -d "$p" ]; then echo "dir"
              else echo "MISSING"; fi
          done'
        ;;
    mount)
        if mountpoint -q "$MNT" 2>/dev/null; then
            echo "  already mounted at $MNT"
        else
            # nmc.sh, never a bare nemoclaw (C-1).
            (cd "$HOME/code/Spark-Hermes" && bash ops/nmc.sh "$AGENT" share mount) 2>&1 | tail -2
        fi

        # The sandbox-side half. /sandbox/shared must exist before the symlink
        # resolves; create it as `sandbox` so the agent can write to it — a
        # root-created dir here is unwritable by uid 998, which is what broke
        # `memory index` on 2026-08-21.
        docker exec -u sandbox "$CON" mkdir -p /sandbox/shared
        docker exec -u root "$CON" sh -c '
            ln -sfn /sandbox/shared /shared
            ln -sfn /sandbox/.openclaw/workspace /workspace'
        echo "  symlinks: /shared -> /sandbox/shared, /workspace -> /sandbox/.openclaw/workspace"

        # Verify from the AGENT's point of view, not the host's. A host-side
        # check would pass while the agent still could not resolve the path.
        echo "  --- as the agent sees it ---"
        docker exec -u sandbox "$CON" sh -c '
          for p in /workspace/TODO.md /workspace/runbooks /shared; do
              printf "    %-24s " "$p"; test -e "$p" && echo OK || echo MISSING
          done'
        ;;
    unmount)
        docker exec -u root "$CON" sh -c 'rm -f /shared /workspace' 2>/dev/null
        (cd "$HOME/code/Spark-Hermes" && bash ops/nmc.sh "$AGENT" share unmount) 2>&1 | tail -1
        echo "  symlinks removed, unmounted"
        ;;
    esac
    echo
done

if [ "$ACT" = mount ]; then
cat <<'EOM'
════════════════════════════════════════════
  MOUNTED IS NOT WORKING — prove it
════════════════════════════════════════════
  The paths now resolve. That is a prerequisite, not the result. The runbooks
  also need host content to actually BE in /sandbox/shared (CHANNELS.md,
  state/, slack/, email/) — the mount makes the location reachable, it does not
  populate it.

  Next: populate /sandbox/shared through the host mount, then wait one 15-min
  heartbeat and check whether the inbox is actually triaged. The gateway writes
  its own log INSIDE the sandbox at /tmp/gateway.log — `docker logs` does NOT
  show heartbeat ticks. Looking in the wrong log produced a false "heartbeat is
  dead" diagnosis on 2026-09-04.
EOM
fi
exit $RC
