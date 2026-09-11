#!/usr/bin/env bash
# rebuild-memory-index.sh — rebuild the native-memory vector index with the
# gateway STOPPED, then bring it back.
#
#   bash ops/rebuild-memory-index.sh cecat
#   bash ops/rebuild-memory-index.sh luoji
#
# ── WHY THE GATEWAY MUST BE DOWN ────────────────────────────────────────────
#
# `openclaw memory index --force` fails with `unable to open database file`
# after 61 embedding batches succeed. Worker W-M found what is actually
# happening (runbook/FINDING-memory-index-cantopen.md):
#
# The rebuild is **build-aside-then-swap**. It writes a sidecar
#     openclaw-agent.sqlite.memory-reindex-<uuid>   (+ -wal, -shm)
# — observed live at 7.9 MB with a 4.3 MB WAL — and then atomically replaces
# the live index. The sidecar is created FINE. The failure is at the swap.
#
# Meanwhile the running gateway holds `openclaw-agent.sqlite` open with a live
# WAL. A swap that must rename/unlink over a database with live WAL readers is
# the classic place SQLite raises SQLITE_CANTOPEN. Evidence the contention is
# real: the gateway RETRIES the rebuild on its own schedule — W-M saw a fresh
# sidecar appear with no CLI running — so two rebuilds can also race each other.
#
# That the swap never completes explains every symptom: embeddings succeed, the
# stamp stays `fts-only`, and all 164 rows keep `embedding = '[]'`.
#
# **This script is a TEST as much as a fix.** If the rebuild succeeds with the
# gateway down, contention was the cause. If it still fails, the fault is inside
# the sidecar open itself and the next lever is SQLITE_TMPDIR (see the FINDING).
#
# ── WHAT IT DOES NOT DO ─────────────────────────────────────────────────────
#
# It deletes NOTHING. W-M proposed removing the stale reindex-lock and any
# leftover sidecars, but that is C-0b and is deliberately NOT done here — the
# gateway-down rebuild is the cheaper, non-destructive discriminator and should
# be tried first.
#
# Downtime: the agent is offline for the duration (minutes). Per GOALS.md no
# agent is production, so this is acceptable — but it IS real downtime.
set -uo pipefail

AGENT="${1:-}"
case "$AGENT" in
    cecat|luoji) ;;
    *) echo "Usage: $0 <cecat|luoji>" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
CON="$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)"
[ -z "$CON" ] && { echo "FAIL: no running sandbox container for $AGENT" >&2; exit 1; }

echo "════════════════════════════════════════════"
echo "  $AGENT — rebuild memory index (gateway down)"
echo "  container: $CON"
echo "════════════════════════════════════════════"

echo
echo "── 1. stopping gateway ──"
BEFORE="$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null || true)"
echo "   pid before: ${BEFORE:-none}"
docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' 2>/dev/null || true

# The container supervisor respawns the gateway, so poll until it is really
# gone rather than assuming a fixed sleep is enough.
GONE=0
for _ in $(seq 1 10); do
    sleep 2
    if [ -z "$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null || true)" ]; then
        GONE=1; break
    fi
done
if [ "$GONE" -ne 1 ]; then
    echo "   WARNING: gateway still running (supervisor respawned it fast)."
    echo "   The rebuild will race it exactly as before. Continuing anyway so the"
    echo "   result is still informative, but treat a failure as inconclusive."
else
    echo "   gateway stopped"
fi

echo
echo "── 2. rebuilding index (several minutes; no output = working) ──"
timeout 1800 docker exec -u sandbox \
    -e OPENCLAW_HOME=/sandbox \
    -e SQLITE_TMPDIR=/tmp \
    -e TMPDIR=/tmp \
    "$CON" openclaw memory index --force --agent main 2>&1 \
  | grep -viE 'batch (start|completed)|trace-warn|^\(node:|Use `node' \
  | tail -8
RC_IDX=${PIPESTATUS[0]}

echo
echo "── 3. restarting gateway ──"
# The supervisor normally respawns it; nudge and confirm rather than assume.
docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway >/dev/null 2>&1' || true
UP=""
for _ in $(seq 1 15); do
    sleep 3
    UP="$(docker exec -u sandbox "$CON" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null || true)"
    [ -n "$UP" ] && break
done
if [ -n "$UP" ]; then
    echo "   gateway back up (pid $UP)"
else
    echo "   *** GATEWAY DID NOT COME BACK — restart it: ***"
    echo "   bash ops/restart-openclaw-gateways.sh $AGENT"
fi

echo
echo "── 4. verify ──"
OUT="$(timeout 600 bash "$HERE/nmc.sh" "$AGENT" exec -- openclaw memory status --deep 2>&1 || true)"
for k in 'Provider:' 'Embeddings:' 'Vector store:' 'Dirty:' 'Embedding cache:' 'Index error:'; do
    printf '%s' "$OUT" | grep -m1 "^$k" | sed 's/^/   /'
done

echo
echo "════════════════════════════════════════════"
if printf '%s' "$OUT" | grep -q '^Index error:'; then
    echo "  STILL FAILING with the gateway down."
    echo "  => contention was NOT the cause. Next lever per the FINDING:"
    echo "     the sidecar open itself. See"
    echo "     runbook/FINDING-memory-index-cantopen.md -> 'If it still fails'."
    RC=1
elif printf '%s' "$OUT" | grep -q 'Embedding cache: enabled (0 entries)'; then
    echo "  No index error, but the embedding cache is still EMPTY."
    echo "  Inconclusive — do not call this fixed."
    RC=1
else
    echo "  Looks good. FINAL PROOF is a real query returning ranked hits:"
    echo "    bash ops/nmc.sh $AGENT exec -- openclaw memory search \"gmail triage\""
    RC=0
fi
echo
echo "  C-12: restore the default gateway →  bash ops/agent-planes.sh status"
echo "════════════════════════════════════════════"
exit "$RC"
