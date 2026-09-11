#!/usr/bin/env bash
# reset-sessions-openshell.sh — scheduled context-overflow guard for the
# OpenShell OpenClaw agents (cecat :8090, luoji :8091).
#
#   bash ops/reset-sessions-openshell.sh            # --check (default): report only
#   bash ops/reset-sessions-openshell.sh --commit   # archive + rename + recreate
#
# Gandalf is Hermes on the :8080 plane. He is NOT handled here and must not be
# added (C-2).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# An OpenClaw session transcript accumulates until the prompt exceeds the
# model's context window. When it does the failure is TOTAL and SILENT: every
# heartbeat dies in *precheck* before the model emits a token, and
# auto-compaction cannot recover because compaction is itself a model call
# carrying the same oversized prompt.
#
# Measured on cecat 2026-09-07: last successful turn 14:39:53Z, first
# context-overflow-diag 14:51:01Z, then 122 dead ticks through 04:51:01Z on
# 09-08 — ~14 hours, 0 assistant tokens, compactionTokens frozen at 116708 on
# every attempt. She kept answering Slack the whole time, so nothing looked
# wrong. Only an external reset clears this.
#
# The legacy guard (shared/scripts/cron/reset-sessions.sh, 4x/day) was swept
# into .attic during the T2 migration with no decision-log entry. This is its
# replacement, retargeted at OpenShell.
#
# ── HOW THE THRESHOLD IS CALIBRATED — READ BEFORE CHANGING IT ───────────────
#
# Three candidate signals, only one of which is usable:
#
#   bytes/4          WRONG. Measured on luoji's live transcript: 1,229,236 B
#                    => 307,309 estimated tokens, vs an ACTUAL last-reported
#                    42,935. A 7.2x overestimate. Thresholding on bytes resets
#                    healthy agents constantly and destroys working context.
#
#   preflightEstimatedTokens   This is the number the gate actually enforces,
#                    but it is only ever emitted by [context-overflow-diag]
#                    AFTER the prompt has already been rejected. It detects an
#                    outage in progress; it cannot prevent one. Used below as a
#                    backstop, not as the primary trigger.
#
#   message.usage.totalTokens  The provider's own count for the most recent
#                    turn, recorded in the transcript. Monotonic within a
#                    session. This is the primary trigger.
#
# The catch: totalTokens systematically UNDERSTATES the gate. At the moment
# cecat died her last recorded totalTokens was 83,826 while precheck rejected
# the next prompt at 116,708 — a ratio of 1.392. So a threshold of 90,000 on
# totalTokens WOULD NEVER HAVE FIRED; she would have died first, exactly as she
# did. The threshold must sit below the observed death point, not below the
# context window.
#
# Default 70,000 => projected gate ~97,400 against a 131,072 window (~74%),
# leaving real headroom for one more large turn. Erring low is deliberate: per
# project framing a lost session costs near zero, a silent 14-hour outage does
# not.
#
# CALIBRATION IS ONE DATA POINT (cecat, 2026-09-07). If another overflow occurs,
# recompute PROJECTION_RATIO from the diag line vs the transcript's last
# totalTokens and revisit.
#
# ── WHAT GETS TOUCHED ───────────────────────────────────────────────────────
#
# Each session is two files:
#   <id>.jsonl              the TRANSCRIPT the model replays  <- reset target
#   <id>.trajectory.jsonl   observability sidecar, ~4x larger <- LEFT ALONE
# The sidecar is forensic evidence; it is how the 2026-09-07 root cause was
# found. The legacy script thresholded on bytes and so mostly archived the
# sidecar, reclaiming disk while the agent still died.
#
# NOTHING IS EVER DELETED. There is no `rm` in this script. A triggered session
# is copied to the host archive, the copy is verified byte-for-byte with cmp,
# and only then is the live file RENAMED to <id>.jsonl.reset.<ts> in place.
# Recovery is a mv.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check)  ACT=check ;;
    --commit) ACT=commit ;;
    *) echo "Usage: $0 [--check|--commit]" >&2; exit 1 ;;
esac

TOKEN_THRESHOLD="${TOKEN_THRESHOLD:-70000}"
CONTEXT_WINDOW="${CONTEXT_WINDOW:-131072}"
PROJECTION_RATIO="${PROJECTION_RATIO:-1.392}"   # measured gate/transcript skew

BASE_DIR="$HOME/code/spark-ai-agents"
ARCHIVE_DIR="$BASE_DIR/shared/session-archives/$(date -u +%Y-%m-%d)"
LOG_FILE="$BASE_DIR/shared/logs/sessions-reset.log"
NOW="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

AGENTS="cecat:8090 luoji:8091"

mkdir -p "$(dirname "$LOG_FILE")" || true

log() { echo "$NOW | $*" >> "$LOG_FILE"; echo "$*"; }

# Walk a JSONL transcript and print: <lastTotalTokens|NONE> <usageRecs> <recs> <badLines>
read_tokens() {
    python3 -c '
import sys, json
last = None; nu = 0; nr = 0; bad = 0
try:
    fh = open(sys.argv[1], "r", errors="replace")
except OSError:
    print("ERR 0 0 0"); sys.exit(0)
for line in fh:
    line = line.strip()
    if not line:
        continue
    nr += 1
    try:
        d = json.loads(line)
    except Exception:
        bad += 1
        continue
    m = d.get("message")
    if isinstance(m, dict):
        u = m.get("usage")
        if isinstance(u, dict) and isinstance(u.get("totalTokens"), int):
            nu += 1
            last = u["totalTokens"]
print("%s %d %d %d" % ("NONE" if last is None else last, nu, nr, bad))
' "$1" 2>/dev/null || echo "ERR 0 0 0"
}

# Registered sessions from sessions.json, as "<sessionKey> <sessionId> <basename|->".
#
# The registry records `sessionFile` as an absolute IN-SANDBOX path
# (/sandbox/.openclaw/...). Only its basename is meaningful on the host, where
# the same directory is reached through the sshfs mount. That basename is the
# authoritative answer to "which file is live" — after a compaction OpenClaw
# rotates the session and the successor is named "<ISO-ts>_<uuid>.jsonl", so the
# bare "<uuid>.jsonl" no longer exists (observed on cecat 2026-09-08T05:21:35Z).
read_sessions() {
    python3 -c '
import sys, json, posixpath
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
for k, v in d.items():
    if not isinstance(v, dict):
        continue
    sid = v.get("sessionId")
    if not sid or str(sid).startswith("nemoclaw-onboard-warmup-"):
        continue
    sf = v.get("sessionFile")
    base = posixpath.basename(sf) if isinstance(sf, str) and sf else "-"
    if "/" in base or not base:
        base = "-"
    print("%s %s %s" % (k, sid, base))
' "$1" 2>/dev/null
}

# Count [context-overflow-diag] lines for this session newer than the
# transcript's own mtime. If the agent is wedged the transcript stops growing
# while the diags keep coming, so this is a direct "dead right now" signal.
count_recent_overflow() {
    local logf="$1" sid="$2" since="$3" n=0 ts epoch
    [ -f "$logf" ] || { echo 0; return; }
    while IFS= read -r ts; do
        epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || continue
        [ -n "$epoch" ] && [ "$epoch" -gt "$since" ] && n=$((n + 1))
    done < <(sed -e 's/\x1b\[[0-9;]*m//g' "$logf" 2>/dev/null \
             | grep -F 'context-overflow-diag' \
             | grep -F "$sid" \
             | awk '{print $1}')
    echo "$n"
}

TARGET_FAIL=0     # mount down / dir missing / no sessions -> loud, non-zero exit
TRIGGERED=0
RESET_OK=0
RESET_FAIL=0
CHECKED_AGENTS=0
CHECKED_SESSIONS=0
MAX_SEEN=0

echo "════════════════════════════════════════════════════════════════"
echo "  reset-sessions-openshell  mode=$ACT  $NOW"
echo "  threshold=${TOKEN_THRESHOLD} tok (projected gate x${PROJECTION_RATIO}"
echo "  vs ${CONTEXT_WINDOW} window)"
echo "════════════════════════════════════════════════════════════════"

for entry in $AGENTS; do
    AGENT="${entry%%:*}"
    PORT="${entry##*:}"
    MNT="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT"
    SESSIONS="$MNT/.openclaw/agents/main/sessions"
    GWLOG="$MNT/.openclaw/logs/gateway-persistent.log"

    echo
    echo "── $AGENT (plane $PORT) ─────────────────────────────────────────"

    # TARGETING FAILURE #1 — mount down. Without this check the session dir
    # resolves to an empty host directory and the script would cheerfully
    # report "nothing to do" during a total outage.
    if ! mountpoint -q "$MNT" 2>/dev/null; then
        log "TARGETING-FAILURE | $AGENT | sshfs mount NOT up at $MNT"
        echo "   >>> cannot see this agent's filespace. Sessions NOT checked. <<<"
        echo "   >>> repair: bash ops/mount-agent-filespaces.sh --check      <<<"
        TARGET_FAIL=$((TARGET_FAIL + 1))
        continue
    fi

    # TARGETING FAILURE #2 — session directory missing behind a live mount.
    if [ ! -d "$SESSIONS" ]; then
        log "TARGETING-FAILURE | $AGENT | mount up but $SESSIONS is missing"
        TARGET_FAIL=$((TARGET_FAIL + 1))
        continue
    fi

    REG="$SESSIONS/sessions.json"
    SESSION_LIST=""
    if [ -f "$REG" ]; then
        SESSION_LIST="$(read_sessions "$REG")"
    fi

    # Fall back to mtime ordering if the registry is unreadable.
    if [ -z "$SESSION_LIST" ]; then
        echo "   note: sessions.json unusable — falling back to newest *.jsonl"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case "$(basename "$f")" in
                sessions.json|*.reset.*|nemoclaw-onboard-warmup-*) continue ;;
            esac
            SESSION_LIST="mtime-fallback $(basename "$f" .jsonl)"
            break
        done < <(ls -t "$SESSIONS"/*.jsonl 2>/dev/null)
    fi

    # TARGETING FAILURE #3 — mount up, directory present, but nothing found.
    # The legacy script's silent `reset=0` is exactly this case, and it is
    # indistinguishable from health. Make it non-zero and unmistakable.
    if [ -z "$SESSION_LIST" ]; then
        log "TARGETING-FAILURE | $AGENT | ZERO sessions found under $SESSIONS"
        echo "   >>> mount is up but no session transcripts were found.      <<<"
        echo "   >>> this is NOT 'healthy' — the guard is blind for $AGENT.  <<<"
        TARGET_FAIL=$((TARGET_FAIL + 1))
        continue
    fi

    CHECKED_AGENTS=$((CHECKED_AGENTS + 1))

    # read_sessions emits THREE fields: "<sessionKey> <sessionId> <basename|->".
    # Reading only two makes SID swallow the trailing basename, so every lookup
    # misses and the run reports a cheerful "sessions=0 / PASS" — the exact
    # silent no-op this script exists to prevent. Caught 2026-09-08 in review.
    while IFS=' ' read -r SKEY SID SREGBASE; do
        [ -n "${SID:-}" ] || continue
        SREGBASE="${SREGBASE:--}"

        # Resolve the transcript for this session id. OpenClaw rotates a session
        # on compaction and names the successor "<ISO-ts>_<uuid>.jsonl", so the
        # plain "<uuid>.jsonl" form is NOT the only possibility — observed live
        # on cecat 2026-09-08T05:21:35Z. Prefer the newest match of either form;
        # assuming the bare name silently misses the live file after a rotation.
        LIVE=""
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            case "$(basename "$cand")" in
                *.reset.*) continue ;;
            esac
            LIVE="$cand"; break
        done < <(ls -t "$SESSIONS/$SID.jsonl" "$SESSIONS"/*_"$SID".jsonl 2>/dev/null)

        if [ -z "$LIVE" ] || [ ! -f "$LIVE" ]; then
            echo "   $SKEY"
            echo "      session $SID registered but transcript absent — skipped"
            continue
        fi

        CHECKED_SESSIONS=$((CHECKED_SESSIONS + 1))
        BYTES="$(stat -c %s "$LIVE" 2>/dev/null || echo 0)"
        MTIME="$(stat -c %Y "$LIVE" 2>/dev/null || echo 0)"
        read -r TOK NU NR BAD <<<"$(read_tokens "$LIVE")"

        OVF="$(count_recent_overflow "$GWLOG" "$SID" "$MTIME")"

        REASON=""
        TRIGGER=0

        if [ "$TOK" = "ERR" ]; then
            # Unreadable is not "healthy" — say so and keep going.
            echo "   $SKEY  session=$SID"
            echo "      UNREADABLE transcript ($BYTES bytes) — NOT evaluated"
            log "READ-FAILURE | $AGENT | $SID | could not read $LIVE"
            TARGET_FAIL=$((TARGET_FAIL + 1))
            continue
        fi

        if [ "$TOK" = "NONE" ]; then
            # Fresh or just-reset transcript: legitimately has no usage record.
            # Not a trigger, not an error. But a LARGE file with no usage
            # records means the parse is wrong, and that must be loud.
            PROJ=0
            if [ "$BYTES" -gt 65536 ]; then
                echo "   $SKEY  session=$SID"
                echo "      $BYTES bytes / $NR records but ZERO usage records"
                echo "      >>> parser may be wrong for this format — investigate <<<"
                log "PARSE-SUSPECT | $AGENT | $SID | ${BYTES}B ${NR}rec 0 usage"
                TARGET_FAIL=$((TARGET_FAIL + 1))
                continue
            fi
            DISPLAY_TOK="none-yet"
        else
            PROJ="$(python3 -c "print(int($TOK * $PROJECTION_RATIO))" 2>/dev/null || echo 0)"
            DISPLAY_TOK="$TOK"
            [ "$TOK" -gt "$MAX_SEEN" ] && MAX_SEEN="$TOK"
            if [ "$TOK" -ge "$TOKEN_THRESHOLD" ]; then
                TRIGGER=1
                REASON="tokens ${TOK} >= ${TOKEN_THRESHOLD} (projected gate ~${PROJ}/${CONTEXT_WINDOW})"
            fi
        fi

        # Backstop: the agent is already wedged. Fires regardless of the token
        # threshold, which is what protects us if the calibration above is off.
        if [ "${OVF:-0}" -gt 0 ]; then
            TRIGGER=1
            REASON="ALREADY DEAD — ${OVF} context-overflow-diag since last transcript write${REASON:+; }${REASON}"
        fi

        BADNOTE=""
        [ "${BAD:-0}" -gt 0 ] && BADNOTE=" / ${BAD} UNPARSED"

        echo "   $SKEY"
        echo "      session:    $SID"
        echo "      transcript: ${BYTES} B / ${NR} records / ${NU} usage recs${BADNOTE}"
        echo "      tokens:     ${DISPLAY_TOK}  projected gate: ${PROJ}  threshold: ${TOKEN_THRESHOLD}"
        echo "      overflow diags since last write: ${OVF}"

        if [ "$TRIGGER" -eq 0 ]; then
            echo "      -> OK, no action"
            # Log the numbers even on a no-op. A bare "reset=0" is
            # indistinguishable from a broken guard; a line with real token
            # counts proves the script looked at the right file.
            log "OK | $AGENT | $SID | tokens=${DISPLAY_TOK} proj=${PROJ} thr=${TOKEN_THRESHOLD} bytes=${BYTES}"
            continue
        fi

        TRIGGERED=$((TRIGGERED + 1))
        echo "      -> TRIGGER: $REASON"

        if [ "$ACT" = check ]; then
            log "WOULD-RESET | $AGENT | $SID | $REASON"
            continue
        fi

        mkdir -p "$ARCHIVE_DIR" || {
            log "RESET-FAIL | $AGENT | $SID | cannot create $ARCHIVE_DIR"
            RESET_FAIL=$((RESET_FAIL + 1)); continue; }

        # Derive names from the RESOLVED file, not from "$SID.jsonl" — after a
        # rotation the live basename carries an ISO-timestamp prefix.
        LIVE_BASE="$(basename "$LIVE")"
        ARCHIVE_PATH="$ARCHIVE_DIR/${AGENT}_${LIVE_BASE}"
        # Never clobber an earlier archive from the same day.
        if [ -e "$ARCHIVE_PATH" ]; then
            ARCHIVE_PATH="$ARCHIVE_DIR/${AGENT}_${LIVE_BASE%.jsonl}.${NOW}.jsonl"
        fi

        # 1. Archive to the host, then verify byte-for-byte BEFORE touching
        #    the original. A failed verify aborts with nothing changed.
        if ! cp "$LIVE" "$ARCHIVE_PATH"; then
            log "RESET-FAIL | $AGENT | $SID | archive copy failed, nothing changed"
            RESET_FAIL=$((RESET_FAIL + 1)); continue
        fi
        if ! cmp -s "$LIVE" "$ARCHIVE_PATH"; then
            log "RESET-FAIL | $AGENT | $SID | archive MISMATCH, nothing changed"
            RESET_FAIL=$((RESET_FAIL + 1)); continue
        fi
        echo "      ARCHIVED -> $ARCHIVE_PATH (verified)"

        # 2. Rename in place. Not a delete — recovery is a mv back.
        RESET_PATH="$LIVE.reset.$NOW"
        if ! mv "$LIVE" "$RESET_PATH"; then
            log "RESET-FAIL | $AGENT | $SID | rename failed, archive kept at $ARCHIVE_PATH"
            RESET_FAIL=$((RESET_FAIL + 1)); continue
        fi
        echo "      RENAMED  -> $(basename "$RESET_PATH")"

        # 3. Recreate an empty transcript; the gateway errors on a missing path.
        : > "$LIVE"
        chmod --reference="$RESET_PATH" "$LIVE" 2>/dev/null || chmod 644 "$LIVE"
        echo "      CREATED  -> empty $(basename "$LIVE")"

        log "RESET | $AGENT | $SID | ${BYTES}B tokens=${DISPLAY_TOK} | archived=$ARCHIVE_PATH | $REASON"
        RESET_OK=$((RESET_OK + 1))
    done <<<"$SESSION_LIST"
done

echo
echo "════════════════════════════════════════════════════════════════"
SUMMARY="agents=${CHECKED_AGENTS}/2 sessions=${CHECKED_SESSIONS} maxTokens=${MAX_SEEN} thr=${TOKEN_THRESHOLD} triggered=${TRIGGERED} reset=${RESET_OK} resetfail=${RESET_FAIL} targetfail=${TARGET_FAIL}"

if [ "$TARGET_FAIL" -gt 0 ]; then
    log "TARGETING-FAILURE-SUMMARY | $SUMMARY"
    echo "  *** ${TARGET_FAIL} TARGETING FAILURE(S). The guard did NOT fully run."
    echo "  *** Do NOT read this as 'agents healthy'. Exit 2."
    echo "════════════════════════════════════════════════════════════════"
    exit 2
fi

if [ "$RESET_FAIL" -gt 0 ]; then
    log "PARTIAL | $SUMMARY"
    echo "  *** ${RESET_FAIL} reset(s) FAILED. Archives kept; live files unchanged."
    echo "════════════════════════════════════════════════════════════════"
    exit 3
fi

# A clean pass still states what it looked at and how close the agents are.
# "reset=0" on its own is what let the legacy guard rot unnoticed.
log "PASS | $SUMMARY"
echo "  checked ${CHECKED_AGENTS} agents / ${CHECKED_SESSIONS} sessions"
echo "  highest observed: ${MAX_SEEN} tok  (threshold ${TOKEN_THRESHOLD})"
if [ "$ACT" = check ] && [ "$TRIGGERED" -gt 0 ]; then
    echo "  ${TRIGGERED} session(s) WOULD be reset. Re-run with --commit to act."
    echo "════════════════════════════════════════════════════════════════"
    exit 4
fi
echo "════════════════════════════════════════════════════════════════"
exit 0
