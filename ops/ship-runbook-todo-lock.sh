#!/usr/bin/env bash
# ship-runbook-todo-lock.sh — ship the file-lock fix for RUNBOOK_TODO.md to both
# agents' LIVE runbooks, and install the lock helper luoji is missing.
#
#   bash ops/ship-runbook-todo-lock.sh            # --check (default)
#   bash ops/ship-runbook-todo-lock.sh --commit   # install lib + ship runbook
#   bash ops/ship-runbook-todo-lock.sh --revert   # restore the live runbooks
#
# ── THE DEFECT (W-N audit, 2026-09-10) ──────────────────────────────────────
#
# Both agents' LIVE `RUNBOOK_TODO.md` tells the agent to append directly:
#
#     exec: echo "…" >> /workspace/TODO.md
#
# Host cron `check-todos.sh` writes those SAME two files every 5 minutes. Without
# the advisory lock the writes race and are silently lost. The repo copy records
# the measurement: **15 host + 15 agent concurrent appends — without the lock 4
# of 30 survived; with it, 30 of 30.**
#
# The fix was written to the REPO and never shipped to the LIVE files. That is
# the third instance of this exact pattern (the kill switch and the stale
# HEARTBEAT.md were the other two): a correct fix that never reached the file the
# agent actually reads.
#
# Blast radius is the highest of anything in the audit — TODO.md is the substrate
# for every scheduled action on both agents, and lost writes look exactly like
# the agent ignoring instructions.
#
# ── ORDER MATTERS ───────────────────────────────────────────────────────────
#
# **luoji has no `/shared/scripts/lib/` at all** — only `agent/`. cecat has it
# (filelock.sh + with-file-lock.sh, mode 755, dated Sep 6). Shipping the runbook
# to luoji WITHOUT the helper would break his TODO writes outright instead of
# merely racing them. So this script installs the lib FIRST, per agent, and
# refuses to ship the runbook to an agent whose lib is missing.
#
# Source of truth is the host tree, verified byte-identical to cecat's working
# copy: ~/code/Spark-OpenClaw/shared/scripts/lib/{filelock.sh,with-file-lock.sh}
#
# ── C-0b ────────────────────────────────────────────────────────────────────
#
# --commit OVERWRITES two live runbooks. Each is backed up next to itself as
# RUNBOOK_TODO.md.pre-lock-<ts> first, and --revert restores the newest backup.
# Nothing is deleted. It does NOT restart the gateway — runbooks are read per
# heartbeat, so the change takes effect on the next tick with no restart.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
    *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

REPO="$HOME/code/Spark-OpenClaw"
SRC_LIB="$REPO/shared/scripts/lib"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RC=0

for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    MNT="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT"
    LIVE_RB="$MNT/.openclaw/workspace/runbooks/RUNBOOK_TODO.md"
    LIVE_LIB="$MNT/shared/scripts/lib"
    REPO_RB="$REPO/$AGENT/runbooks/RUNBOOK_TODO.md"

    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    [ -d "$MNT" ] || { echo "  FAIL: mount down at $MNT"; RC=1; continue; }

    if [ "$ACT" = revert ]; then
        BK="$(ls -t "$LIVE_RB".pre-lock-* 2>/dev/null | head -1)"
        [ -z "$BK" ] && { echo "  no pre-lock backup — nothing to revert"; continue; }
        cp "$BK" "$LIVE_RB" && echo "  REVERTED from $(basename "$BK")" || { echo "  FAIL"; RC=1; }
        continue
    fi

    # ── 1. the lock helper ──────────────────────────────────────────────────
    if [ -f "$LIVE_LIB/with-file-lock.sh" ] && [ -f "$LIVE_LIB/filelock.sh" ]; then
        echo "  lib      : present"
        LIB_OK=1
    elif [ "$ACT" = check ]; then
        echo "  lib      : MISSING — would install filelock.sh + with-file-lock.sh"
        LIB_OK=1   # would be satisfied by --commit
    else
        if mkdir -p "$LIVE_LIB" \
           && cp "$SRC_LIB/filelock.sh" "$SRC_LIB/with-file-lock.sh" "$LIVE_LIB/" \
           && chmod 755 "$LIVE_LIB/filelock.sh" "$LIVE_LIB/with-file-lock.sh"; then
            echo "  lib      : INSTALLED (filelock.sh, with-file-lock.sh, mode 755)"
            LIB_OK=1
        else
            echo "  lib      : FAIL to install — NOT shipping the runbook"
            RC=1; LIB_OK=0
        fi
    fi
    [ "${LIB_OK:-0}" -eq 1 ] || continue

    # ── 2. the runbook ──────────────────────────────────────────────────────
    if [ ! -f "$REPO_RB" ]; then
        echo "  runbook  : FAIL — no repo copy at $REPO_RB"; RC=1; continue
    fi
    if cmp -s "$REPO_RB" "$LIVE_RB"; then
        echo "  runbook  : already identical to repo — no change"
        continue
    fi

    if grep -q 'with-file-lock.sh' "$LIVE_RB" 2>/dev/null; then
        echo "  runbook  : live already references the lock (differs for another reason)"
    else
        echo "  runbook  : live uses a LOCKLESS append — needs the fix"
    fi

    if [ "$ACT" = check ]; then
        echo "  --check only. Nothing changed."
        continue
    fi

    cp "$LIVE_RB" "$LIVE_RB.pre-lock-$STAMP" || { echo "  FAIL: backup"; RC=1; continue; }
    echo "  BACKUP   : $(basename "$LIVE_RB").pre-lock-$STAMP"
    if cat "$REPO_RB" > "$LIVE_RB"; then
        echo "  SHIPPED  : repo -> live"
    else
        echo "  FAIL: write"; RC=1
    fi
done

echo "════════════════════════════════════════════"
if [ "$ACT" = check ]; then
    echo "  --check only. To apply:"
    echo "    bash ops/ship-runbook-todo-lock.sh --commit"
    exit "$RC"
fi

if [ "$RC" -eq 0 ]; then
    cat <<'EOF'
  Done. No gateway restart needed — runbooks are read fresh each heartbeat.

  VERIFY (next heartbeat, <=15 min):
    grep -c with-file-lock ~/.nemoclaw/gateways/8090/mounts/cecat/.openclaw/workspace/runbooks/RUNBOOK_TODO.md
    grep -c with-file-lock ~/.nemoclaw/gateways/8091/mounts/luoji/.openclaw/workspace/runbooks/RUNBOOK_TODO.md
    # both should be >= 1

  The real proof is an agent writing a TODO entry that survives alongside a
  cron write — that only shows up under live use, not in a static check.
EOF
else
    echo "  Completed with errors — see FAIL lines above."
fi
exit "$RC"
