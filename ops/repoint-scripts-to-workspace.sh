#!/usr/bin/env bash
# repoint-scripts-to-workspace.sh — stop the runbooks depending on /scripts.
#
#   bash ops/repoint-scripts-to-workspace.sh --check    # report only (default)
#   bash ops/repoint-scripts-to-workspace.sh --commit   # rewrite the runbooks
#
# ── PROGRESS FIRST: the OOM patch WORKED ────────────────────────────────────
#
# Before ops/patch-oom-wrapper.sh, every exec died at:
#   /usr/bin/sh: 1: cannot create /proc/self/oom_score_adj: Permission denied
# Now it dies at:
#   python3: can't open file '/scripts/gmail-api.py': [Errno 13] Permission denied
#
# **The error moved.** exec now runs; the shell prologue no longer aborts. This
# is the next step in the chain failing, not the same failure repeating.
#
# ── THIS BUG ────────────────────────────────────────────────────────────────
#
# `/scripts` is **root-owned** — it belongs to the container image
# (generate-openclaw-config.mts, lib/). The supervisor copied the two api
# wrappers into it earlier because the runbooks say `/scripts/gmail-api.py`.
# That was the wrong place to put them.
#
# The file is mode 755 and readable via `docker exec -u sandbox`, but the
# agent's exec context — hardened seccomp, NoNewPrivs=1, empty capability
# bounding set — gets EACCES. **Same asymmetry that made three prior diagnoses
# wrong: it works from `docker exec` and fails from the agent.** Do not "prove"
# a fix here with docker exec; it tests a path the agent never uses.
#
# ── THE FIX: use the copies that are already in the agent's own tree ────────
#
#   /workspace/scripts/gmail-api.py       sandbox:sandbox 755   (wrapper)
#   /workspace/scripts/gmail-api.real.py  sandbox:sandbox 640   (implementation)
#
# Sandbox-owned, inside the workspace the agent already reads and writes, no
# root-owned directory anywhere in the path. Repointing the runbooks removes
# the dependency instead of fighting the permission model.
#
# **Point at the WRAPPER, never at *.real.py.** The wrapper pins
# GSUITE_MCP_TOKEN_PATH / GSUITE_MCP_CREDENTIALS_PATH before delegating;
# calling .real.py directly bypasses credential pinning and fails on HOME=/root
# (mode 700, unreadable by uid 998).
#
# Also drops the /scripts copies, so a stale root-owned duplicate cannot be
# picked up later and produce this same confusing failure again.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) DO=0 ;; --commit) DO=1 ;;
  *) echo "Usage: $0 [--check|--commit]" >&2; exit 1 ;;
esac

BASE="$HOME/code/Spark-OpenClaw"
RC=0

echo "════════════════════════════════════════════"
echo "  Repoint /scripts -> /workspace/scripts"
echo "════════════════════════════════════════════"

# Host-side runbooks are the source of truth; the sandbox copies live under the
# sshfs mount and are the same files the agent reads.
FILES=$(grep -rl 'exec:.*python3 /scripts/' \
    "$BASE/cecat/runbooks/" "$BASE/luoji/runbooks/" \
    "$BASE/cecat/TOOLS.md" "$BASE/cecat/PATHS.md" 2>/dev/null || true)

if [ -z "$FILES" ]; then
    echo "  no host-side runbook references /scripts/ — checking sandbox copies only"
else
    echo "--- host files referencing /scripts/ ---"
    echo "$FILES" | sed "s|$BASE/|  |"
    echo
    echo "  total refs: $(grep -rhoE 'python3 /scripts/[a-z-]+\.py' $FILES 2>/dev/null | wc -l)"
fi

if [ "$DO" = 0 ]; then
    echo
    echo "  WOULD rewrite:  python3 /scripts/X.py  ->  python3 /workspace/scripts/X.py"
    echo "  WOULD remove the root-owned copies at /scripts/{gmail,contacts}-api.py"
    echo
    echo "  Run with --commit to apply."
    exit 0
fi

echo
echo "--- rewriting host runbooks ---"
for f in $FILES; do
    cp "$f" "$f.pre-repoint"
    sed -i 's|python3 /scripts/|python3 /workspace/scripts/|g' "$f"
    echo "  $(basename "$f")"
done

# The sandbox copies are what the agent actually reads. They live under the
# sshfs mount, so writing them here lands them inside the container.
echo
echo "--- rewriting sandbox copies (via the sshfs mount) ---"
for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    WS="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT/.openclaw/workspace"
    if [ ! -d "$WS" ]; then
        echo "  $AGENT: mount not present — run ops/mount-agent-filespaces.sh --mount" >&2
        RC=1; continue
    fi
    n=0
    for f in "$WS"/runbooks/*.md "$WS"/TOOLS.md "$WS"/PATHS.md; do
        [ -f "$f" ] || continue
        if grep -q 'python3 /scripts/' "$f" 2>/dev/null; then
            sed -i 's|python3 /scripts/|python3 /workspace/scripts/|g' "$f"
            n=$((n+1))
        fi
    done
    echo "  $AGENT: $n file(s) rewritten in-sandbox"
done

# Remove the misplaced root-owned copies. Leaving them invites a future reader
# to "fix" a path back to /scripts and re-create this failure.
echo
echo "--- removing the root-owned copies ---"
for AGENT in cecat luoji; do
    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    [ -n "$CON" ] || continue
    docker exec -u root "$CON" sh -c 'rm -f /scripts/gmail-api.py /scripts/contacts-api.py' 2>/dev/null
    echo "  $AGENT: /scripts copies removed (image tooling untouched)"
done

cat <<'EOM'

════════════════════════════════════════════
  VERIFY — and NOT with docker exec
════════════════════════════════════════════
  `docker exec` bypasses the agent's seccomp context. It has produced three
  false passes today. The only valid test is the agent running the runbook.

  Queue a task and wait one heartbeat (<=15 min):
    C=$(docker ps --format '{{.Names}}' | grep '^openshell-default--cecat-')
    docker exec -u sandbox $C bash /shared/scripts/lib/with-file-lock.sh \
      /workspace/TODO.md "READY | $(date -u +%Y-%m-%dT%H:%M:%SZ) | PLAN: /workspace/runbooks/RUNBOOK_GMAIL_TRIAGE.md"

  Then:
    docker exec -u sandbox $C sh -c 'tail -3 /workspace/TODO.md'

  COMPLETED = the chain works. A new error = progress. The SAME EACCES on
  /workspace/scripts would mean the problem is not the directory owner, and
  that is worth stopping on.

  The real proof is Charlie's inbox.
EOM
exit $RC
