#!/usr/bin/env bash
# check-native-memory.sh — prove native memory has SEMANTIC recall, not just keyword.
#
#   bash ops/check-native-memory.sh
#
# Read-only. Exit 0 only if both agents report embeddings available and the
# vector store enabled.
#
# ── WHAT THIS ACTUALLY MEASURES ─────────────────────────────────────────────
#
# `openclaw memory status --deep` is the build's own diagnostic — use it rather
# than guessing at sqlite paths (the index is at
# agents/main/agent/openclaw-agent.sqlite, not the docs' location).
#
# Baseline measured 2026-09-09 with provider:"none":
#
#   Indexed: 42/43 files · 164 chunks     <- FTS indexing ALREADY WORKS
#   Embeddings: unavailable               <- no embedding provider
#   Embeddings error: No embedding provider available (FTS-only mode)
#   Vector store: disabled
#   Semantic vectors: disabled
#   FTS: ready
#
# So the agents were never "memory-less" — they had keyword search all along.
# What they lacked is SEMANTIC recall: matching on meaning rather than on the
# literal words. That is the whole delta, and it is the thing to verify.
#
# ⚠️ `Indexed: N chunks` is therefore NOT proof of success — it was already true
# while broken. The load-bearing lines are `Embeddings:` and `Vector store:`.
#
# ⚠️ This runs `ops/nmc.sh <agent> exec`, which FLIPS THE GLOBAL DEFAULT GATEWAY
# (C-12). Restore afterwards with:  bash ops/agent-planes.sh status
set -uo pipefail

RC=0

for AGENT in cecat luoji; do
    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    OUT="$(timeout 120 bash "$(dirname "$0")/nmc.sh" "$AGENT" exec -- \
             openclaw memory status --deep 2>&1)" || true

    if ! printf '%s' "$OUT" | grep -q 'Memory Search'; then
        echo "  FAIL     : could not get memory status (gateway down? mount down?)"
        printf '%s\n' "$OUT" | tail -3 | sed 's/^/           /'
        RC=1; continue
    fi

    prov=$(printf '%s' "$OUT" | grep -m1 '^Provider:'      | sed 's/^Provider: *//')
    idx=$( printf '%s' "$OUT" | grep -m1 '^Indexed:'       | sed 's/^Indexed: *//')
    emb=$( printf '%s' "$OUT" | grep -m1 '^Embeddings:'    | sed 's/^Embeddings: *//')
    err=$( printf '%s' "$OUT" | grep -m1 '^Embeddings error:' | sed 's/^Embeddings error: *//')
    vec=$( printf '%s' "$OUT" | grep -m1 '^Vector store:'  | sed 's/^Vector store: *//')
    sem=$( printf '%s' "$OUT" | grep -m1 '^Semantic vectors:' | sed 's/^Semantic vectors: *//')

    echo "  provider : ${prov:-?}"
    echo "  indexed  : ${idx:-?}   (true even when broken — not evidence)"
    echo "  embeddings: ${emb:-?}${err:+  — $err}"
    echo "  vectors  : ${vec:-?} / semantic ${sem:-?}"

    ok=1
    case "$emb" in *unavailable*|"") ok=0 ;; esac
    case "$vec" in *disabled*|"")    ok=0 ;; esac

    if [ "$ok" -eq 1 ]; then
        echo "  ok       : semantic recall is LIVE"
    else
        echo "  FAIL     : FTS-only — keyword search works, meaning-based recall does not."
        echo "             fix: bash ops/apply-native-memory.sh --commit"
        echo "                  bash ops/restart-openclaw-gateways.sh"
        echo "             first index also pulls a ~0.3GB GGUF; allow several minutes."
        RC=1
    fi
done

echo "════════════════════════════════════════════"
if [ "$RC" -eq 0 ]; then
    echo "  PASS — semantic memory live on both agents"
    echo
    echo "  Final proof is a real query (returns ranked hits, not an error):"
    echo "    bash ops/nmc.sh cecat exec -- openclaw memory search \"what does Charlie care about\""
else
    echo "  NOT WORKING YET — see FAIL lines above"
fi
echo "  C-12: restore the default gateway →  bash ops/agent-planes.sh status"
exit "$RC"
