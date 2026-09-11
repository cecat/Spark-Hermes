#!/usr/bin/env bash
# fix-exec-oom.sh — unblock the agents' `exec:` tool.
#
#   bash ops/fix-exec-oom.sh --check     # report only (default)
#   bash ops/fix-exec-oom.sh --commit    # apply + restart the gateway
#
# ── THE BUG ─────────────────────────────────────────────────────────────────
#
# EVERY `exec:` step in EVERY runbook fails before the command runs. From the
# agent's own `lastToolError` (the raw tool result, not her prose summary):
#
#   /usr/bin/sh: 1: cannot create /proc/self/oom_score_adj: Permission denied
#
# OpenClaw wraps every exec'd command in a prologue
# (dist/linux-oom-score-eO5nXmjv.js):
#
#   echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec "$0" "$@"
#
# The `2>/dev/null` does not save it: the REDIRECT fails before suppression
# applies, so `sh` errors and the command never executes. This is why 10+
# consecutive runbook attempts failed identically regardless of which runbook
# ran — it was never about gmail-api.py.
#
# ── WHY IT FAILS FOR THE AGENT AND NOT FOR US — MEASURED ────────────────────
#
#                       gateway (agent exec)   docker exec -u sandbox
#   NoNewPrivs                  1                      0
#   Seccomp_filters             4                      1
#   CapBnd              0000000000000000       00000004a82c35fb
#   write oom_score_adj      BLOCKED                SUCCEEDS
#
# The gateway runs under a hardened seccomp profile with an empty capability
# bounding set. **`docker exec` bypasses it entirely.** Every earlier test used
# `docker exec`, so every test passed while the real path failed — which is how
# three successive diagnoses were confidently wrong.
#
# `/proc/bus`, `/proc/fs`, `/proc/irq` are read-only but `/proc/self` is NOT, so
# the block is the seccomp filter, not a mount.
#
# ── NOT AN OPENCLAW BUG ─────────────────────────────────────────────────────
#
# The wrapper is intentional: openclaw#70404 -> PR #70419, shipped 2026.4.22.
# Our failure mode is reported nowhere upstream — searches for the exact string
# return only podman/crun/conmon/systemd. Upgrading will NOT help: the only
# later OOM change (2026.9.1) extends the wrapper. Skepticism about a
# "frontier-model-discovered OpenClaw bug" was well placed.
#
# ── THE FIX ─────────────────────────────────────────────────────────────────
#
# `OPENCLAW_CHILD_OOM_SCORE_ADJ=0` skips the shim entirely
# (docs.openclaw.ai/platforms/linux; also accepts false/no/off). **Verified by
# grep in our running 2026.7.1 runtime**, not merely read in the docs.
#
# Cost: the gateway becomes the likelier OOM victim instead of its children.
# Irrelevant on a box with no memory pressure — and strictly better than the
# alternative of relaxing seccomp, which would weaken containment to enable a
# feature we do not need.
#
# ── WHERE IT HAS TO GO, AND WHY THAT IS AWKWARD ─────────────────────────────
#
# The var is read from the CHILD env, so the gateway process must carry it.
#
#   - /tmp/nemoclaw-proxy-env.sh is sourced at gateway start (nemoclaw-start:762)
#     but is REGENERATED each start and is mode 444 — appending does not persist.
#   - The container's OPENSHELL_SANDBOX_COMMAND already sets OPENCLAW_* via
#     `env ...`, but changing container env requires recreating the container,
#     which C-4 forbids (no bind mounts; the writable layer is the only copy).
#
# So this script restarts the gateway process **inside** the running container
# with the var exported — no container recreation, nothing destroyed.
#
# **NOT PERSISTENT.** A container restart loses it. Making it durable means
# adding the var to the sandbox launch command, which is a rebuild-time change
# and belongs in the deploy hook. Until then this must be re-run after any
# container restart — and it fails SILENTLY, exactly like the mount and the
# symlinks.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) DO=0 ;; --commit) DO=1 ;;
  *) echo "Usage: $0 [--check|--commit]" >&2; exit 1 ;;
esac

RC=0
for AGENT in cecat luoji; do
    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    [ -n "$CON" ] || { echo "$AGENT: no sandbox"; continue; }

    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    P=$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null)
    if [ -z "$P" ]; then echo "  gateway not running"; RC=1; continue; fi

    CUR=$(docker exec -u root "$CON" sh -c "tr '\0' '\n' < /proc/$P/environ | grep '^OPENCLAW_CHILD_OOM_SCORE_ADJ=' || true")
    if [ -n "$CUR" ]; then
        echo "  already set: $CUR"
        continue
    fi
    echo "  OPENCLAW_CHILD_OOM_SCORE_ADJ: not set (this is the bug)"

    if [ "$DO" = 0 ]; then
        echo "  WOULD restart the gateway with OPENCLAW_CHILD_OOM_SCORE_ADJ=0"
        continue
    fi

    echo "  --- restarting gateway with the opt-out ---"
    # Same SIGTERM pattern the apply-*-slack scripts use: PID 1 does not trap
    # SIGTERM, so `docker restart` would not reach the gateway. The supervisor
    # respawns it — and it inherits the env we set here.
    docker exec -u sandbox -e OPENCLAW_CHILD_OOM_SCORE_ADJ=0 "$CON" \
        sh -c 'pkill -TERM -f openclaw-gateway' || true
    sleep 10

    NEW=$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null)
    if [ -z "$NEW" ]; then
        echo "  GATEWAY DID NOT COME BACK — investigate before doing anything else" >&2
        RC=1; continue
    fi
    echo "  gateway back as pid $NEW"

    GOT=$(docker exec -u root "$CON" sh -c "tr '\0' '\n' < /proc/$NEW/environ | grep '^OPENCLAW_CHILD_OOM_SCORE_ADJ=' || echo 'NOT INHERITED'")
    echo "  env on new process: $GOT"
    case "$GOT" in
        NOT*) echo "  ** the respawn did not inherit it — see NOTE below **" >&2; RC=1 ;;
    esac
    echo
done

cat <<'EOM'
════════════════════════════════════════════
  NOTE IF THE ENV WAS NOT INHERITED
════════════════════════════════════════════
  The gateway is respawned by a supervisor process, which may hand it a fixed
  environment rather than the one used to kill the old process. If so, the var
  must go in the sandbox LAUNCH COMMAND (OPENSHELL_SANDBOX_COMMAND), which is a
  container-level change — a rebuild, and C-0b territory. Report the output
  rather than forcing it.

  VERIFY THE ACTUAL FIX — the env var is not the proof:
    C=$(docker ps --format '{{.Names}}' | grep '^openshell-default--cecat-')
    docker exec -u sandbox $C sh -c 'tail -3 /workspace/TODO.md'

  A line flipping FAILED -> COMPLETED means exec works. The REAL proof is
  Charlie's inbox actually being triaged.
EOM
exit $RC
