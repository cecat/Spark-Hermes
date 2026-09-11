#!/usr/bin/env bash
# fix-memory-index-dirs.sh — create the missing state dirs that break the
# native-memory index rebuild, then rebuild and verify.
#
#   bash ops/fix-memory-index-dirs.sh            # --check (default): report only
#   bash ops/fix-memory-index-dirs.sh --commit   # mkdir + reindex + verify
#
# ── THE BUG ─────────────────────────────────────────────────────────────────
#
# `openclaw memory index --force` fails with:
#
#     Memory index failed (main): unable to open database file
#
# ...but only AFTER 61 embedding batches complete successfully. The model, the
# llama-cpp provider, the config, the GGUF download and sqlite-vec are all fine
# (each verified individually). The failure is one write at the very end.
#
# `openclaw memory status --deep` names two paths:
#
#     Recall path:     plugin-state:memory-core/short-term-recall/<hash>
#     Embedding cache: enabled (0 entries)
#
# Neither `/sandbox/.openclaw/plugin-state` nor `/sandbox/.openclaw/cache`
# EXISTS in either sandbox. SQLite returns exactly `unable to open database
# file` when a database's PARENT DIRECTORY is absent — reproduced directly:
#
#     >>> sqlite3.connect('/tmp/nonexistent-dir-xyz/test.sqlite').execute(...)
#     unable to open database file
#
# That is why every database inspected was healthy: the failing one was never
# created, because its directory is not there.
#
# ── WHY THIS IS SAFE ────────────────────────────────────────────────────────
#
# It only CREATES directories. Nothing is deleted, moved or overwritten, so it
# is not a C-0b action. If the directories already exist it changes nothing.
# Mode 2770 (drwxrws---) matches every sibling under .openclaw; the setgid bit
# keeps group ownership consistent for files the gateway creates later.
#
# ── CONFIDENCE ──────────────────────────────────────────────────────────────
#
# The error string matches exactly and the directories are genuinely missing,
# but it is NOT proven that memory-core writes to those specific paths — the
# core runtime is inside the container and not readable from the host. If the
# reindex still fails after this, the mkdir was not the cause and the remaining
# candidate is a path this script does not know about. The verify step below
# will say so plainly rather than reporting a false success.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;;
    *) echo "Usage: $0 [--check|--commit]" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
RC=0

for pair in "cecat:8090" "luoji:8091"; do
    AGENT="${pair%%:*}"; PORT="${pair##*:}"
    OC="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT/.openclaw"

    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    if [ ! -d "$OC" ]; then
        echo "  FAIL: $OC unreachable — is the sshfs mount up?"
        echo "        bash ops/mount-agent-filespaces.sh --check"
        RC=1; continue
    fi

    for d in plugin-state cache; do
        if [ -d "$OC/$d" ]; then
            echo "  exists   : $d"
        elif [ "$ACT" = check ]; then
            echo "  MISSING  : $d   (would create, mode 2770)"
        else
            if mkdir -p "$OC/$d" && chmod 2770 "$OC/$d"; then
                echo "  CREATED  : $d ($(stat -c %A "$OC/$d"))"
            else
                echo "  FAIL     : could not create $d"; RC=1
            fi
        fi
    done
done

if [ "$ACT" = check ]; then
    echo "════════════════════════════════════════════"
    echo "  --check only. Nothing changed."
    echo "  To apply:  bash ops/fix-memory-index-dirs.sh --commit"
    exit "$RC"
fi

[ "$RC" -ne 0 ] && { echo "Directory step failed — not reindexing."; exit "$RC"; }

# ── Rebuild ─────────────────────────────────────────────────────────────────
# The stored index is stamped `fts-only` from when no embedding provider
# existed. Vector search stays PAUSED until it is rebuilt with the real model,
# so --force is required; a normal sync will not clear the stamp.
echo
echo "════════════════════════════════════════════"
echo "  Rebuilding indexes (several minutes each)"
echo "════════════════════════════════════════════"

for AGENT in cecat luoji; do
    echo
    echo "── $AGENT: reindex ──"
    if timeout 1800 bash "$HERE/nmc.sh" "$AGENT" exec -- \
         openclaw memory index --force 2>&1 \
         | grep -viE 'trace-warn|^\(node:|Use `node|Active gateway|proxy\]|EnvHttpProxy|batch (start|completed)' \
         | tail -6
    then :; fi

    echo "── $AGENT: verify ──"
    OUT="$(timeout 600 bash "$HERE/nmc.sh" "$AGENT" exec -- \
             openclaw memory status --deep 2>&1 || true)"
    for k in 'Provider:' 'Embeddings:' 'Vector store:' 'Semantic vectors:' 'Dirty:' 'Embedding cache:' 'Index error:'; do
        printf '%s' "$OUT" | grep -m1 "^$k" | sed 's/^/    /'
    done

    if printf '%s' "$OUT" | grep -q '^Index error:'; then
        echo "    >>> STILL FAILING — the missing directories were NOT the cause."
        echo "    >>> See runbook/FINDING-memory-index-cantopen.md (worker W-M)."
        RC=1
    elif printf '%s' "$OUT" | grep -q '^Embedding cache: enabled (0 entries)'; then
        echo "    >>> cache still empty — reindex may not have written vectors."
        RC=1
    else
        echo "    >>> looks good — confirm with a real query below."
    fi
done

echo
echo "════════════════════════════════════════════"
if [ "$RC" -eq 0 ]; then
    echo "  Reindex reported no errors."
    echo
    echo "  FINAL PROOF — a semantic query must return ranked hits, not"
    echo "  'No matches'. Absence of error is NOT evidence:"
    echo
    echo "    bash ops/nmc.sh cecat exec -- openclaw memory search \"gmail triage\""
    echo "    bash ops/nmc.sh luoji exec -- openclaw memory search \"drive upload\""
else
    echo "  NOT FIXED — see the STILL FAILING lines above."
fi
echo
echo "  C-12: nmc.sh flipped the default gateway. Restore it:"
echo "    bash ops/agent-planes.sh status"
echo "════════════════════════════════════════════"
exit "$RC"
