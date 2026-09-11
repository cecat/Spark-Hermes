#!/usr/bin/env bash
# test-file-lock.sh — prove the shared-file lock works from INSIDE the sandbox.
#
#   bash ops/test-file-lock.sh
#
# The supervisor verified filelock.sh host-side (stale-lock breaking, timeout
# with holder identification, release-on-failure, 30/30 concurrent appends
# surviving vs 4/30 without). What it could not run is the agent side — the
# permission classifier blocks docker exec writes. This script closes that gap.
#
# It appends a clearly-marked LOCKTEST line to cecat's TODO.md exactly the way
# RUNBOOK_TODO.md now instructs the agent to, then removes it again. Read-only
# in effect: the file ends as it began.
set -u

C=$(docker ps --format '{{.Names}}' | grep '^openshell-default--cecat-' | head -1)
[ -n "$C" ] || { echo "no cecat sandbox running" >&2; exit 1; }

MARK="2026-09-06T18:30:00Z | LOCKTEST delete-me"

# `docker exec ... wc -l < /workspace/TODO.md` redirects from the HOST, where
# that path does not exist — the shell opens the file before docker ever runs.
# The redirect has to happen inside the container.
BEFORE=$(docker exec -u sandbox "$C" sh -c 'wc -l < /workspace/TODO.md' 2>/dev/null)

echo "════════════════════════════════════════════"
echo "  Lock test — agent side"
echo "════════════════════════════════════════════"
echo "  TODO.md lines before: $BEFORE"
echo

echo "--- 1. helper reachable from inside the sandbox? ---"
docker exec -u sandbox "$C" test -r /shared/scripts/lib/with-file-lock.sh \
    && echo "  /shared/scripts/lib/with-file-lock.sh  OK" \
    || { echo "  MISSING — the lib was not copied into /shared" >&2; exit 1; }

echo
echo "--- 2. append via the lock, as the runbook instructs ---"
docker exec -u sandbox "$C" bash /shared/scripts/lib/with-file-lock.sh /workspace/TODO.md "$MARK"
RC=$?
echo "  exit code: $RC  (0 = appended)"

echo
echo "--- 3. did the line actually land? ---"
docker exec -u sandbox "$C" tail -1 /workspace/TODO.md

echo
echo "--- 4. was the lock released, not leaked? ---"
if docker exec -u sandbox "$C" test -d /workspace/TODO.md.lockdir; then
    echo "  LEAKED — /workspace/TODO.md.lockdir still exists" >&2
    RC=1
else
    echo "  released cleanly"
fi

echo
echo "--- 5. clean up the test line ---"
# grep -v into a temp then copy back IN PLACE. Never `mv` across this boundary:
# the file is owned by uid 998 and a rename cannot preserve that.
docker exec -u sandbox "$C" sh -c \
    'grep -v "LOCKTEST delete-me" /workspace/TODO.md > /tmp/todo.clean && cat /tmp/todo.clean > /workspace/TODO.md && rm -f /tmp/todo.clean'
AFTER=$(docker exec -u sandbox "$C" sh -c 'wc -l < /workspace/TODO.md' 2>/dev/null)
echo "  TODO.md lines after cleanup: $AFTER  (should equal $BEFORE)"

echo
echo "════════════════════════════════════════════"
if [ "$RC" = 0 ] && [ "$AFTER" = "$BEFORE" ]; then
    echo "  PASS — the agent can write shared files under the lock."
    echo
    echo "  Still NOT done: cron does not take the lock yet, and host cron"
    echo "  still writes a DIFFERENT TODO.md than the one the agent reads."
    echo "  The lock makes a shared file safe; it does not make these two"
    echo "  files one file. That is the remaining design step."
else
    echo "  FAIL — exit $RC, before=$BEFORE after=$AFTER. Paste this output back."
fi
echo "════════════════════════════════════════════"
exit $RC
