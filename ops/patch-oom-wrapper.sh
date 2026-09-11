#!/usr/bin/env bash
# patch-oom-wrapper.sh — neuter the OOM prologue that breaks every agent exec.
#
#   bash ops/patch-oom-wrapper.sh --check     # report only (default)
#   bash ops/patch-oom-wrapper.sh --commit    # patch + restart gateways
#   bash ops/patch-oom-wrapper.sh --revert    # restore from backup
#
# ── ONE LINE, ONE BUG ───────────────────────────────────────────────────────
#
# dist/linux-oom-score-eO5nXmjv.js:21
#
#   const OOM_SCORE_WRAP_SCRIPT =
#     "echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec \"$0\" \"$@\"";
#
# OpenClaw wraps EVERY exec'd command in that prologue. Under this sandbox's
# seccomp profile the redirect is refused, `sh` aborts with
#
#   /usr/bin/sh: 1: cannot create /proc/self/oom_score_adj: Permission denied
#
# and the command never runs. `2>/dev/null` does not save it — the redirect
# fails before the suppression applies. This breaks every `exec:` in every
# runbook, which is why 10+ attempts failed identically no matter which runbook
# ran. It was never about gmail-api.py.
#
# The patch drops the failing write and keeps the exec:
#
#   const OOM_SCORE_WRAP_SCRIPT = "exec \"$0\" \"$@\"";
#
# ── WHY THIS, AND NOT THE TWO "PROPER" FIXES ────────────────────────────────
#
# `OPENCLAW_CHILD_OOM_SCORE_ADJ=0` is the documented opt-out and was tried
# first. It does not reach the gateway: `nemoclaw-start` runs as PID 1,
# generates /tmp/nemoclaw-proxy-env.sh from ITS OWN environment, and every
# gateway respawn sources that file. Setting the var on a `docker exec` does
# not survive the respawn — verified, "NOT INHERITED" on both agents. Landing
# it properly means changing the container's launch env, i.e. recreating the
# sandbox (C-4: no bind mounts, the writable layer is the only copy).
#
# Relaxing seccomp would fix the cause but weakens containment — which GOALS.md
# names as the one area where "simplest thing that works" does not apply.
#
# Charlie's framing decided it: recreating a sandbox to enable an OOM
# optimisation on a box with no memory pressure is a $100 fix for a $1 problem.
# This is the $1 fix. **Its purpose is to PROVE the diagnosis**: if triage runs
# afterwards, the whole pipeline is confirmed and only persistence remains.
#
# ── WHAT IT COSTS ───────────────────────────────────────────────────────────
#
# Exec'd children are no longer preferred OOM-kill victims, so under memory
# pressure the kernel may kill the gateway instead of a transient child. There
# is no memory pressure on this box.
#
# **It lives in the writable layer and dies on rebuild** — like the sshfs mount
# and the /workspace and /shared symlinks. That is now FOUR things that vanish
# silently on restart. They belong in the deploy hook together, and that is the
# next piece of work regardless of how this test turns out.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
  *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

F=/usr/local/lib/nemoclaw/openclaw-runtime/node_modules/openclaw/dist/linux-oom-score-eO5nXmjv.js
BAK="${F}.pre-oom-patch"
OLD='const OOM_SCORE_WRAP_SCRIPT = "echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec \\"$0\\" \\"$@\\"";'
NEW='const OOM_SCORE_WRAP_SCRIPT = "exec \\"$0\\" \\"$@\\"";'

RC=0
for AGENT in cecat luoji; do
    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    [ -n "$CON" ] || { echo "$AGENT: no sandbox"; continue; }

    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    if ! docker exec -u sandbox "$CON" test -f "$F" 2>/dev/null; then
        echo "  runtime file not found — skipping"; RC=1; continue
    fi

    # `grep -c` prints 0 AND exits 1 when there are no matches, so the old
    # `... || echo 0` idiom fired too and produced the TWO-LINE string "0\n0",
    # which fails every `= "0"` test below. Effect: a correctly-patched agent
    # was reported UNPATCHED — a false negative in a repair tool, which invites
    # someone to "fix" something that already works. Found 2026-09-08 (W-G2),
    # reproduced by the supervisor. `head -1` collapses it; an EMPTY result is
    # kept distinct from 0 because "the check itself failed" and "no matches"
    # point at opposite actions.
    PATCHED=$(docker exec -u sandbox "$CON" sh -c "grep -c 'oom_score_adj 2>/dev/null; exec' $F 2>/dev/null" | head -1)
    if [ -z "$PATCHED" ]; then
        echo "  CHECK FAILED — could not read $F in $CON (not 'unpatched'; the probe itself failed)"
        RC=1; continue
    fi

    case "$ACT" in
    check)
        if [ "$PATCHED" = "0" ]; then
            echo "  already patched (or line not present)"
        else
            echo "  UNPATCHED — the OOM prologue is active and breaking every exec"
            docker exec -u sandbox "$CON" sh -c "sed -n '21p' $F" | cut -c1-110 | sed 's/^/    /'
        fi
        ;;
    commit)
        if [ "$PATCHED" = "0" ]; then echo "  already patched — nothing to do"; continue; fi
        docker exec -u root "$CON" sh -c "[ -f '$BAK' ] || cp '$F' '$BAK'"
        echo "  backup: $(basename $BAK)"

        # python3, not sed: the line is dense with quotes and backslashes, and a
        # sed expression that mangles it would leave the runtime unparseable.
        docker exec -u root -i "$CON" python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec '
if old not in s:
    print("  MARKER NOT FOUND — not modified"); sys.exit(1)
s = s.replace(old, 'exec ')
open(p, "w").write(s)
print("  patched: prologue removed, exec preserved")
PY
        [ $? -eq 0 ] || { echo "  patch failed"; RC=1; continue; }

        docker exec -u sandbox "$CON" sh -c "node --check $F >/dev/null 2>&1" \
            && echo "  syntax OK (node --check)" \
            || echo "  note: node --check unavailable or failed; continuing"

        echo "  --- restarting gateway ---"
        docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' || true
        sleep 10
        NEWPID=$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null)
        [ -n "$NEWPID" ] && echo "  gateway back as pid $NEWPID" \
                         || { echo "  GATEWAY DID NOT RETURN — revert before anything else" >&2; RC=1; }
        ;;
    revert)
        docker exec -u root "$CON" sh -c "[ -f '$BAK' ] && cp '$BAK' '$F' && echo restored || echo 'no backup'"
        docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' || true
        sleep 8
        echo "  reverted and gateway restarted"
        ;;
    esac
    echo
done

if [ "$ACT" = commit ]; then
cat <<'EOM'
════════════════════════════════════════════
  THE TEST — one heartbeat, then the inbox
════════════════════════════════════════════
  cecat wakes every 15 min; cron promotes hourly at :00. The next tick after a
  fresh promotion is the real test.

  Watch the task line:
    docker exec -u sandbox $(docker ps --format '{{.Names}}' \
      | grep '^openshell-default--cecat-') sh -c 'tail -3 /workspace/TODO.md'

  FAILED -> COMPLETED means exec works and the whole chain is proven.
  A NEW failure reason is still progress — the next runbook step is executing.
  The same oom_score_adj error means the diagnosis was wrong; STOP and say so.

  **The real proof is Charlie's inbox being triaged.** Not the log, not the
  task line.
EOM
fi
exit $RC
