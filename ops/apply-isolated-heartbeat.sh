#!/usr/bin/env bash
# apply-isolated-heartbeat.sh — stop the heartbeat accumulating one immortal session.
#
#   bash ops/apply-isolated-heartbeat.sh            # --check (default): diff only
#   bash ops/apply-isolated-heartbeat.sh --commit   # patch config (does NOT restart)
#   bash ops/apply-isolated-heartbeat.sh --revert   # restore the pre-change backup
#
# ── WHAT THIS FIXES — the FIRST-ORDER cause of two total outages ────────────
#
# cecat went completely dark twice (2026-09-07 ~14h, 2026-09-08) — every
# heartbeat rejected in precheck, zero tokens emitted. The chain, all verified:
#
#   agents.list = one agent `main`, heartbeat every 15m, **isolation: null**
#   -> every tick appends to ONE never-reset session
#   -> 3-8 model calls per tick, ~5 avg = ~480 model calls/day (measured)
#   -> the session crosses the 131,072-token window
#   -> every subsequent heartbeat dies in precheck, forever
#
# `isolatedSession: true` means each heartbeat runs in a fresh session with no
# prior history. **History cannot accrue, so the cliff cannot be reached and
# compaction stops being load-bearing.** One key per agent.
#
# This is the minimal, first-order fix. It does NOT stop the heartbeat paying an
# LLM to run `ls` and `grep` 96 times a day — that is step 2 (an `openclaw cron`
# job with `--trigger-script` and `--command`, both verified present in this
# build; see runbook/DESIGN-heartbeat-deterministic.md). Do step 1 alone first
# and verify it before touching anything else.
#
# ── WHAT IS DELIBERATELY *NOT* SET ──────────────────────────────────────────
#
# **`lightContext` stays OFF.** It skips workspace bootstrap files, and
# HEARTBEAT.md is how the agent learns what a heartbeat *is*. Combined with
# `skipBootstrap: true` — already set in agents.defaults — it could produce a
# heartbeat that wakes with no instructions. **Cheaper and deaf is worse than
# expensive.**
#
# luoji's `activeHours` block is preserved untouched (08:00-22:00 America/
# Chicago; an out-of-hours tick gap is correct, not a fault).
#
# ── VERIFY AFTER RESTART — the second half is the real test ─────────────────
#
# 1. a `[heartbeat]` line dated after the restart in
#    <mount>/.openclaw/logs/gateway-persistent.log
# 2. **a READY item in /workspace/TODO.md actually flipping to COMPLETED**
#
# (2) is what proves an isolated session still has its instructions. (1) alone
# only proves the tick fired. A heartbeat that wakes with no context would look
# identical to a healthy one in the log — that is the failure mode to rule out.
#
# **Keep ops/reset-sessions-openshell.sh until this has survived a full cycle.**
#
# ── C-0b ────────────────────────────────────────────────────────────────────
# --commit overwrites a live config. It backs up first and --revert restores.
# It does NOT restart the gateway; restarting is a live control action.
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
        echo "  FAIL: config unreachable at $CFG"
        echo "        is the sshfs mount up?  bash ops/mount-agent-filespaces.sh --check"
        RC=1; continue
    fi

    if [ "$ACT" = revert ]; then
        BK="$(ls -t "$MNT/.openclaw/"openclaw.json.pre-isolated-* 2>/dev/null | head -1)"
        if [ -z "$BK" ]; then echo "  FAIL: no pre-isolated backup found"; RC=1; continue; fi
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

lst = (d.get("agents") or {}).get("list")
if not isinstance(lst, list) or not lst:
    print("NO_AGENT_LIST"); raise SystemExit(0)

changed = []
for entry in lst:
    if not isinstance(entry, dict):
        continue
    hb = entry.get("heartbeat")
    if not isinstance(hb, dict):
        continue                      # no heartbeat on this agent — leave alone
    if hb.get("isolatedSession") is True:
        continue                      # already set
    hb["isolatedSession"] = True
    changed.append(entry.get("id", "?"))

if not changed:
    print("ALREADY"); raise SystemExit(0)
print("PATCH %s" % ",".join(changed))
print(json.dumps(d, indent=2))
PY
)"

    STATUS="$(printf '%s\n' "$OUT" | head -1)"
    case "$STATUS" in
        PARSE_FAIL*|NO_AGENT_LIST)
            echo "  FAIL: $STATUS"; RC=1; continue ;;
        ALREADY)
            echo "  isolatedSession already true — no change"; continue ;;
    esac

    echo "  heartbeat.isolatedSession: (unset) -> true   [agents: ${STATUS#PATCH }]"

    if [ "$ACT" = check ]; then
        echo "  --check only. Nothing changed."
        continue
    fi

    BK="$MNT/.openclaw/openclaw.json.pre-isolated-$STAMP"
    cp "$CFG" "$BK" || { echo "  FAIL: backup"; RC=1; continue; }
    echo "  BACKUP -> $(basename "$BK")"

    TMP="$CFG.tmp-isolated-$STAMP"
    printf '%s\n' "$OUT" | tail -n +2 > "$TMP"
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null; then
        echo "  FAIL: patched JSON does not parse — original untouched"
        rm -f "$TMP" 2>/dev/null; RC=1; continue
    fi
    cat "$TMP" > "$CFG" && rm -f "$TMP" || { echo "  FAIL: write"; RC=1; continue; }
    echo "  PATCHED"
done

if [ "$ACT" = commit ] && [ "$RC" -eq 0 ]; then
    cat <<'EOF'

  Config patched. Heartbeat settings are read at gateway start, so each gateway
  must be restarted. Restarting is a live control action — run it yourself.

  THEN VERIFY, and (2) is the one that matters:
    1. a [heartbeat] line dated after the restart in
         <mount>/.openclaw/logs/gateway-persistent.log
    2. a READY item in /workspace/TODO.md flipping to COMPLETED

  (2) proves the isolated session still has its instructions. A heartbeat that
  wakes with no context looks IDENTICAL to a healthy one in the log.

  Watch token growth flatten:
    bash ops/reset-sessions-openshell.sh --check
  maxTokens should stop climbing across ticks. Keep that guard installed until
  this has survived a full cycle.
EOF
fi

exit "$RC"
