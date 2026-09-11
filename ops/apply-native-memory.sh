#!/usr/bin/env bash
# apply-native-memory.sh — turn on native OpenClaw memory for cecat and luoji.
#
#   bash ops/apply-native-memory.sh            # --check (default): diff only
#   bash ops/apply-native-memory.sh --commit   # patch config (does NOT restart)
#   bash ops/apply-native-memory.sh --revert   # restore the pre-change backup
#
# ── WHAT WAS BROKEN ─────────────────────────────────────────────────────────
#
# Both agents carried `memorySearch: { "provider": "none" }`. Native memory was
# OFF: they consulted memory only because their .md files told them to read
# files, never through native memory tools. Verified — the `memory/` dir is
# empty (dated Aug 12) and the gateway state DB has 68 tables and not one
# memory/embedding/vector table. Nothing was ever indexed.
#
# OpenClaw's default provider is `openai`, which needs an API token; with no
# token the indexer fails SILENTLY. That is how this hid for months.
#
# ── THE FIX: provider "local" ───────────────────────────────────────────────
#
# The documented answer for a self-hosted box (W-K, docs.openclaw.ai/reference/
# memory-config): `provider: "local"` runs the embedding model IN-PROCESS via
# node-llama-cpp. No API key, no host service, no socat bridge, no L7 egress
# preset, no coupling to FALDA or Ollama. It auto-downloads
# `embeddinggemma-300m-qat-Q8_0.gguf` (~0.3 GB) on first index; OpenShell ships
# a built-in `huggingface` egress preset for that fetch.
#
# ⚠️ PATH: the docs say `memory.search.provider`. **That path does not exist in
# 2026.7.1** — `memory` has only {backend, citations, qmd}. On this build the
# key lives at `agents.defaults.memorySearch`, which is where our `"none"`
# already sits. Only the VALUE is wrong. Do NOT "correct" the path to match the
# docs; it would be silently ignored. (The docs describe a later rename.)
#
# Deliberately NOT set — every one is already a correct default, and each extra
# key is another thing to get wrong:
#   fallback  leave unset ("none"). Every alternative needs a credential we do
#             not have; an unauthenticated fallback is a silent-failure
#             generator. Explicit failure is the goal here.
#   model / local.modelPath   unset — auto-download is the documented default.
#   store / chunking / sync / query / cache   all defaulted and sensible;
#             store.vector (sqlite-vec) and cache are already true.
#   experimental.sessionMemory   off. Indexing transcripts raises cost and
#             widens the secrets surface.
#
# ── C-0b ────────────────────────────────────────────────────────────────────
# --commit overwrites a live config. Backs up first; --revert restores. It does
# NOT restart the gateway — that is a live control action.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
    *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RC=0

for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    MNT="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT"
    CFG="$MNT/.openclaw/openclaw.json"

    echo "════════════════════════════════════════════"
    echo "  $AGENT (plane $PORT)"
    echo "════════════════════════════════════════════"

    if [ ! -f "$CFG" ]; then
        echo "  FAIL: config unreachable at $CFG (is the sshfs mount up?)"; RC=1; continue
    fi

    if [ "$ACT" = revert ]; then
        BK="$(ls -t "$MNT/.openclaw/"openclaw.json.pre-memory-* 2>/dev/null | head -1)"
        [ -z "$BK" ] && { echo "  FAIL: no pre-memory backup found"; RC=1; continue; }
        cp "$BK" "$CFG" && echo "  REVERTED from $(basename "$BK")" || { echo "  FAIL: restore"; RC=1; }
        continue
    fi

    OUT="$(python3 - "$CFG" <<'PY'
import json, sys
cfg = sys.argv[1]
try:
    d = json.load(open(cfg))
except Exception as e:
    print("PARSE_FAIL %s" % e); raise SystemExit(0)

defaults = (d.get("agents") or {}).get("defaults")
if not isinstance(defaults, dict):
    print("NO_DEFAULTS"); raise SystemExit(0)

cur  = defaults.get("memorySearch") or {}
want = {"enabled": True, "provider": "local", "sources": ["memory"]}
if cur == want:
    print("ALREADY"); raise SystemExit(0)

defaults["memorySearch"] = want
print("PATCH %s" % json.dumps(cur))
print(json.dumps(d, indent=2))
PY
)"

    STATUS="$(printf '%s\n' "$OUT" | head -1)"
    case "$STATUS" in
        PARSE_FAIL*|NO_DEFAULTS) echo "  FAIL: $STATUS"; RC=1; continue ;;
        ALREADY) echo "  memorySearch already set to local — no change"; continue ;;
    esac

    echo "  memorySearch: ${STATUS#PATCH }"
    echo '             -> {"enabled": true, "provider": "local", "sources": ["memory"]}'

    if [ "$ACT" = check ]; then echo "  --check only. Nothing changed."; continue; fi

    BK="$MNT/.openclaw/openclaw.json.pre-memory-$STAMP"
    cp "$CFG" "$BK" || { echo "  FAIL: backup"; RC=1; continue; }
    echo "  BACKUP -> $(basename "$BK")"

    TMP="$CFG.tmp-memory-$STAMP"
    printf '%s\n' "$OUT" | tail -n +2 > "$TMP"
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null; then
        echo "  FAIL: patched JSON does not parse — original untouched"; rm -f "$TMP"; RC=1; continue
    fi
    cat "$TMP" > "$CFG" && rm -f "$TMP" || { echo "  FAIL: write"; RC=1; continue; }
    echo "  PATCHED"
done

if [ "$ACT" = commit ] && [ "$RC" -eq 0 ]; then
    cat <<'EOF'

  Config patched. Restart each gateway to pick it up:
      bash ops/restart-openclaw-gateways.sh
  (NEVER ops/apply-heartbeat.sh — it strips agents.list[].heartbeat and would
   undo isolatedSession. See C-16.)

  ── VERIFY — the original bug was SILENT, so "no error" proves nothing ──────
  Require positive evidence that vectors exist. First index also pulls a
  ~0.3 GB GGUF, so allow several minutes after the restart.

    bash ops/check-native-memory.sh
EOF
fi

exit "$RC"
