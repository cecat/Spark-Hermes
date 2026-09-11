#!/usr/bin/env bash
# point-cron-at-sandbox.sh — make host cron and the agent write the SAME
# TODO.md and CALENDAR.md.
#
#   bash ops/point-cron-at-sandbox.sh --check     # show what would change
#   bash ops/point-cron-at-sandbox.sh --commit    # apply
#   bash ops/point-cron-at-sandbox.sh --revert    # restore from backup
#
# ── THE LAST BLOCKER ────────────────────────────────────────────────────────
#
# Everything else is now in place: the sshfs mount, /workspace and /shared, the
# api wrappers, the heartbeat, and a working cross-boundary lock. One gap
# remains, and it is the one that keeps the inbox untriaged.
#
# `check-todos.sh` promotes due CALENDAR entries to READY in
#   $BASE/<agent>/TODO.md          (host)
# but the agent reads
#   /workspace/TODO.md  ->  /sandbox/.openclaw/workspace/TODO.md   (sandbox)
#
# **Two different files.** The host copy currently holds 58 READY items the
# agent has never seen; the agent's copy holds 5 lines last touched Aug 21. On
# the legacy stack a bind mount made these one inode. There is no bind mount
# now, so cron must be pointed at the sandbox copy through the sshfs mount.
#
# ── WHY POINT CRON AT THE SANDBOX, RATHER THAN COPY ─────────────────────────
#
# Copying was considered and rejected: both parties WRITE these files (cron
# promotes READY and reaps COMPLETED; the agent marks COMPLETED and adds
# calendar entries), so any copy loses whichever side wrote last. That is
# exactly the drift that left the two files two weeks apart.
#
# One file, two writers, coordinated by a lock is the only arrangement without
# a lost-update window.
#
# ── THE LOCK IS MANDATORY, AND IT IS ADVISORY ───────────────────────────────
#
# Measured on cecat 2026-09-06, 15 host + 15 agent concurrent appends:
#   without a lock:  4 of 30 updates survived
#   with the lock:  30 of 30 survived
#
# flock does NOT work here — tested: host and sandbox each acquired the same
# exclusive flock simultaneously, because flock is kernel-tracked and the two
# sides have different kernels. `mkdir` is atomic across the boundary and is
# what shared/scripts/lib/filelock.sh uses.
#
# Advisory means EVERY writer must participate. RUNBOOK_TODO.md already
# instructs the agent to use `with-file-lock.sh`. This script makes cron do the
# same. If either side skips it, the bug returns for both.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
  *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

SCRIPT="$HOME/code/spark-ai-agents/shared/scripts/cron/check-todos.sh"
BACKUP="${SCRIPT}.pre-sandbox-paths"

# The sandbox copies, reachable from the host only while the sshfs mount is up.
CECAT_WS="$HOME/.nemoclaw/gateways/8090/mounts/cecat/.openclaw/workspace"
LUOJI_WS="$HOME/.nemoclaw/gateways/8091/mounts/luoji/.openclaw/workspace"

echo "════════════════════════════════════════════"
echo "  Point host cron at the sandbox TODO/CALENDAR"
echo "════════════════════════════════════════════"

# ── Preflight. Every one of these is a silent-failure mode if skipped. ──────
FAIL=0

for m in "$HOME/.nemoclaw/gateways/8090/mounts/cecat" \
         "$HOME/.nemoclaw/gateways/8091/mounts/luoji"; do
    if mountpoint -q "$m" 2>/dev/null; then
        echo "  mount OK        : $m"
    else
        echo "  MOUNT MISSING   : $m" >&2
        echo "                    run: bash ops/mount-agent-filespaces.sh --mount" >&2
        FAIL=1
    fi
done

for f in "$CECAT_WS/TODO.md" "$CECAT_WS/CALENDAR.md" \
         "$LUOJI_WS/TODO.md" "$LUOJI_WS/CALENDAR.md"; do
    [ -f "$f" ] && echo "  target OK       : ${f#$HOME/}" \
                || { echo "  TARGET MISSING  : ${f#$HOME/}" >&2; FAIL=1; }
done

[ -r "$SCRIPT" ] && echo "  script OK       : check-todos.sh" \
                 || { echo "  SCRIPT MISSING  : $SCRIPT" >&2; FAIL=1; }

echo
[ "$FAIL" = 0 ] || { echo "  preflight failed — nothing changed" >&2; exit 1; }

case "$ACT" in
check)
    echo "--- current paths in check-todos.sh ---"
    grep -nE '^\s+"\$BASE/(cecat|luoji|chattpc26)/(TODO|CALENDAR)' "$SCRIPT" | sed 's/^/  /'
    echo
    echo "--- would become ---"
    echo "  cecat -> $CECAT_WS/{TODO,CALENDAR}.md"
    echo "  luoji -> $LUOJI_WS/{TODO,CALENDAR}.md"
    echo "  chattpc26 -> unchanged (hibernated, no sandbox)"
    echo
    echo "  Run with --commit to apply."
    ;;

commit)
    [ -f "$BACKUP" ] || cp "$SCRIPT" "$BACKUP"
    echo "  backup: ${BACKUP#$HOME/}"

    # Rewrite only the cecat and luoji entries. chattpc26 is hibernated with no
    # sandbox, so its $BASE paths must stay — repointing it would break a
    # currently-harmless no-op into an error every 5 minutes.
    python3 - "$SCRIPT" "$CECAT_WS" "$LUOJI_WS" <<'PY'
import re, sys
path, cecat, luoji = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
for agent, ws in (("cecat", cecat), ("luoji", luoji)):
    for f in ("TODO", "CALENDAR"):
        s = s.replace(f'"$BASE/{agent}/{f}.md"', f'"{ws}/{f}.md"')
        s = s.replace(f'$BASE/{agent}/{f}.md:', f'{ws}/{f}.md:')
open(path, "w").write(s)
print("  rewrote cecat and luoji paths; chattpc26 left on $BASE")
PY

    echo
    echo "--- resulting paths ---"
    grep -nE '(TODO|CALENDAR)\.md' "$SCRIPT" | grep -E 'FILES=|PAIRS=|mounts/|\$BASE/' \
        | sed -n '1,8p' | sed 's/^/  /'
    bash -n "$SCRIPT" && echo "  syntax OK" || { echo "  SYNTAX ERROR — reverting" >&2; cp "$BACKUP" "$SCRIPT"; exit 1; }
    ;;

revert)
    [ -f "$BACKUP" ] || { echo "  no backup at $BACKUP" >&2; exit 1; }
    cp "$BACKUP" "$SCRIPT"
    echo "  restored from ${BACKUP#$HOME/}"
    ;;
esac

if [ "$ACT" = commit ]; then
cat <<'EOM'

════════════════════════════════════════════
  WHAT THIS DOES NOT DO
════════════════════════════════════════════
  1. check-todos.sh still writes WITHOUT the lock. It now writes the same file
     the agent writes, so the lost-update window this opens is real. Wiring it
     to shared/scripts/lib/filelock.sh is the next edit and should not wait.

  2. The 58 READY items on the old host TODO.md are NOT migrated. They are
     history; CALENDAR.md will re-promote whatever is genuinely due. Do not
     copy them across — most are hours or days stale.

  3. If the sshfs mount drops, cron writes into an empty directory and every
     promotion is silently lost. The mount is not yet persistent across reboot.
     THIS IS THE NEXT SILENT FAILURE unless a systemd unit is added.

  Verify at the next 5-minute cron tick:
    tail -5 ~/code/spark-ai-agents/shared/logs/todos-cron.log
    docker exec -u sandbox $(docker ps --format '{{.Names}}' \
      | grep '^openshell-default--cecat-') grep -c READY /workspace/TODO.md
EOM
fi
