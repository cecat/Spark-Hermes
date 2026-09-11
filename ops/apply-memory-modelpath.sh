#!/usr/bin/env bash
# apply-memory-modelpath.sh — set the documented local-embedding keys that the
# earlier config change omitted.
#
#   bash ops/apply-memory-modelpath.sh            # --check (default)
#   bash ops/apply-memory-modelpath.sh --commit   # patch config
#   bash ops/apply-memory-modelpath.sh --revert   # restore backup
#
# ── WHY ─────────────────────────────────────────────────────────────────────
#
# `openclaw memory index --force` now fails with:
#
#     EACCES: permission denied, mkdir '/root/.node-llama-cpp/models'
#
# The gateway resolves `~` to **/root**, which is mode 700 and unreadable by the
# sandbox user (uid 998). This is the standing `HOME=/root` trap already
# recorded in constraints.md — it has bitten `gog` and `gmail-api.py` before.
#
# The docs list `local.modelCacheDir` as the supported override
# (default `~/.openclaw/models/llama.cpp`, "remains authoritative for managed
# setup") and `local.modelPath` as part of the local-provider config
# (docs.openclaw.ai/plugins/llama-cpp). **Both were omitted from the first
# config patch on the reasoning that auto-download made them unnecessary. That
# reasoning was wrong**: auto-download still needs a writable cache dir, and
# without `modelCacheDir` it targets an unwritable `$HOME`.
#
# Sets, per runbook/HOWTO-openclaw-memory.md:
#   memorySearch.model                 the hf: model id
#   memorySearch.local.modelPath       same id (explicit, per docs)
#   memorySearch.local.modelCacheDir   /sandbox/.openclaw/models/llama.cpp
#                                      — absolute, owned by uid 998
#
# The already-downloaded GGUF at /sandbox/.node-llama-cpp/models/ is left alone;
# if the runtime re-fetches into the new cache dir that is ~0.3 GB once, and the
# HF CDN egress preset is already in place.
#
# ── C-0b ────────────────────────────────────────────────────────────────────
# Overwrites a live config. Backs up first (openclaw.json.pre-modelpath-<ts>);
# --revert restores. Does NOT restart the gateway.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
    *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

MODEL="hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf"
CACHE="/sandbox/.openclaw/models/llama.cpp"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RC=0

for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    OC="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT/.openclaw"
    CFG="$OC/openclaw.json"

    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    [ -f "$CFG" ] || { echo "  FAIL: $CFG unreachable (mount down?)"; RC=1; continue; }

    if [ "$ACT" = revert ]; then
        BK="$(ls -t "$OC"/openclaw.json.pre-modelpath-* 2>/dev/null | head -1)"
        [ -z "$BK" ] && { echo "  FAIL: no pre-modelpath backup"; RC=1; continue; }
        cp "$BK" "$CFG" && echo "  REVERTED from $(basename "$BK")" || { echo "  FAIL"; RC=1; }
        continue
    fi

    OUT="$(python3 - "$CFG" "$MODEL" "$CACHE" <<'PY'
import json, sys
cfg, model, cache = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(cfg))
except Exception as e:
    print("PARSE_FAIL %s" % e); raise SystemExit(0)
ms = ((d.get("agents") or {}).get("defaults") or {}).get("memorySearch")
if not isinstance(ms, dict):
    print("NO_MEMORYSEARCH"); raise SystemExit(0)
want_local = {"modelPath": model, "modelCacheDir": cache}
if ms.get("model") == model and ms.get("local") == want_local:
    print("ALREADY"); raise SystemExit(0)
ms["model"] = model
ms["local"] = want_local
print("PATCH")
print(json.dumps(d, indent=2))
PY
)"
    STATUS="$(printf '%s\n' "$OUT" | head -1)"
    case "$STATUS" in
        PARSE_FAIL*|NO_MEMORYSEARCH) echo "  FAIL: $STATUS"; RC=1; continue ;;
        ALREADY) echo "  already set — no change"; continue ;;
    esac

    echo "  model          -> $MODEL"
    echo "  local.modelPath-> (same)"
    echo "  local.modelCacheDir -> $CACHE"

    if [ "$ACT" = check ]; then echo "  --check only. Nothing changed."; continue; fi

    cp "$CFG" "$OC/openclaw.json.pre-modelpath-$STAMP" || { echo "  FAIL: backup"; RC=1; continue; }
    echo "  BACKUP -> openclaw.json.pre-modelpath-$STAMP"

    TMP="$CFG.tmp-modelpath-$STAMP"
    printf '%s\n' "$OUT" | tail -n +2 > "$TMP"
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null; then
        echo "  FAIL: patched JSON does not parse — original untouched"; rm -f "$TMP"; RC=1; continue
    fi
    cat "$TMP" > "$CFG" && rm -f "$TMP" || { echo "  FAIL: write"; RC=1; continue; }

    # The cache dir must exist and be writable by uid 998 before first use.
    mkdir -p "$OC/models/llama.cpp" && chmod 2770 "$OC/models" "$OC/models/llama.cpp" \
        && echo "  CREATED  models/llama.cpp ($(stat -c %A "$OC/models/llama.cpp"))" \
        || { echo "  FAIL: could not create cache dir"; RC=1; }
    echo "  PATCHED"
done

if [ "$ACT" = commit ] && [ "$RC" -eq 0 ]; then
    cat <<'EOF'

  Next:
    bash ops/restart-openclaw-gateways.sh
    bash ops/rebuild-memory-index.sh cecat
    bash ops/rebuild-memory-index.sh luoji

  Watch for the EACCES on /root to be gone. If a NEW path appears in the error,
  that is progress — report it rather than guessing at the next fix.
EOF
fi
exit "$RC"
