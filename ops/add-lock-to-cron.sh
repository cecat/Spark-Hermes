#!/usr/bin/env bash
# add-lock-to-cron.sh — make check-todos.sh take the shared-file lock, and stop
# it using `mv` across the sshfs boundary.
#
#   bash ops/add-lock-to-cron.sh --check    # show what would change (default)
#   bash ops/add-lock-to-cron.sh --commit   # apply
#   bash ops/add-lock-to-cron.sh --revert   # restore from backup
#
# ── TWO BUGS, SAME TWO LINES ────────────────────────────────────────────────
#
# check-todos.sh now writes the SAME TODO.md the agent writes (repointed by
# ops/point-cron-at-sandbox.sh). That exposes two defects that were harmless
# while the files were separate:
#
# **1. No lock.** Measured on cecat 2026-09-06 — 15 host + 15 agent concurrent
#    appends: without a lock 4 of 30 updates survived; with the lock 30 of 30.
#    The losses are silent. A task the agent marked COMPLETED reappears, or a
#    promotion cron made never arrives.
#
# **2. `mv "$tmp" "$file"` does not work across sshfs.** The host writes as
#    `catlett`; the target is owned by uid 998 (`sandbox`). Rename cannot
#    preserve ownership and fails with
#    `mv: failed to preserve ownership ... Permission denied`, sometimes
#    leaving the target MISSING. Observed directly during testing. The fix is
#    `cat "$tmp" > "$file"` — writes the bytes in place, leaves the inode and
#    its ownership alone.
#
# Both write sites are the same shape (`done < "$file" > "$tmp"`, then a
# conditional `mv`), in cleanup_completed() and mark_ready().
#
# ── WHY NOT JUST WRAP THE WHOLE SCRIPT IN ONE LOCK ──────────────────────────
#
# Because it processes three agents in sequence. One outer lock would hold
# cecat's lock while working on luoji, serialising unrelated work and widening
# the window in which the agent is blocked. Per-file locking around each
# read-modify-write keeps holds to milliseconds.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
  *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

SCRIPT="$HOME/code/Spark-OpenClaw/shared/scripts/cron/check-todos.sh"
BACKUP="${SCRIPT}.pre-lock"
LIB="$HOME/code/Spark-OpenClaw/shared/scripts/lib/filelock.sh"

echo "════════════════════════════════════════════"
echo "  Add file locking to check-todos.sh"
echo "════════════════════════════════════════════"

[ -r "$SCRIPT" ] || { echo "  missing: $SCRIPT" >&2; exit 1; }
[ -r "$LIB" ]    || { echo "  missing: $LIB" >&2; exit 1; }
echo "  script OK : check-todos.sh"
echo "  lib OK    : filelock.sh"
echo

case "$ACT" in
check)
    echo "--- the two unsafe write sites ---"
    grep -nE 'mv "\$tmp" "\$file"' "$SCRIPT" | sed 's/^/  /'
    echo
    echo "--- would become ---"
    echo '  cat "$tmp" > "$file"   # in-place; mv cannot preserve uid 998 over sshfs'
    echo "  ...each wrapped so the read-modify-write holds the lock"
    echo
    echo "--- does it source the lock library yet? ---"
    grep -q 'filelock.sh' "$SCRIPT" && echo "  yes" || echo "  NO — would be added"
    echo
    echo "  Run with --commit to apply."
    ;;

commit)
    [ -f "$BACKUP" ] || cp "$SCRIPT" "$BACKUP"
    echo "  backup: ${BACKUP#$HOME/}"

    python3 - "$SCRIPT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()

# 1. Source the lock library, right after the audit lib it already sources.
if "filelock.sh" not in s:
    anchor = 'source "$HOME/code/Spark-OpenClaw/shared/scripts/lib/audit.sh"'
    if anchor in s:
        s = s.replace(anchor, anchor +
            '\n# Shared-file lock. TODO.md/CALENDAR.md are written by BOTH this script\n'
            '# and the agent; without coordination ~87% of concurrent updates are lost.\n'
            'source "$HOME/code/Spark-OpenClaw/shared/scripts/lib/filelock.sh"', 1)
    else:
        # Fall back to inserting after the shebang block rather than failing.
        lines = s.split("\n")
        for i, l in enumerate(lines):
            if l.startswith("set -"):
                lines.insert(i + 1,
                    'source "$HOME/code/Spark-OpenClaw/shared/scripts/lib/filelock.sh"')
                break
        s = "\n".join(lines)

# 2. Replace `mv "$tmp" "$file"` with an in-place copy under the lock.
#    mv across sshfs fails: cannot preserve uid 998 from the host side.
old = '        mv "$tmp" "$file"'
new = ('        # In-place, NOT mv: the target is owned by uid 998 and reached\n'
       '        # over sshfs, where rename cannot preserve ownership.\n'
       '        if filelock_acquire "$file"; then\n'
       '            cat "$tmp" > "$file"\n'
       '            filelock_release "$file"\n'
       '        else\n'
       '            echo "check-todos: LOCK TIMEOUT on $file — skipping this pass" >&2\n'
       '        fi\n'
       '        rm -f "$tmp"')
n = s.count(old)
s = s.replace(old, new)
open(p, "w").write(s)
print(f"  rewrote {n} write site(s) to lock + in-place copy")
PY

    bash -n "$SCRIPT" && echo "  syntax OK" \
        || { echo "  SYNTAX ERROR — reverting" >&2; cp "$BACKUP" "$SCRIPT"; exit 1; }

    echo
    echo "--- verify: no bare mv left, lock is sourced ---"
    if grep -qE 'mv "\$tmp" "\$file"' "$SCRIPT"; then
        echo "  WARNING: a bare mv survived — inspect manually" >&2
    else
        echo "  no bare mv remaining"
    fi
    grep -q 'filelock.sh' "$SCRIPT" && echo "  filelock.sh sourced" || echo "  WARNING: lib not sourced" >&2
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
  VERIFY AT THE NEXT 5-MINUTE TICK
════════════════════════════════════════════
  tail -5 ~/code/Spark-OpenClaw/shared/logs/todos-cron.log

  A "LOCK TIMEOUT" line means the agent held the lock longer than 30s — worth
  investigating, but the pass is skipped safely rather than clobbering.

  Both writers now take the lock. The lock is ADVISORY: it only works because
  every writer participates. Anything else that edits TODO.md must use
  shared/scripts/lib/with-file-lock.sh.
EOM
fi
