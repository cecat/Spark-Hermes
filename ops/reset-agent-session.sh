#!/usr/bin/env bash
# reset-agent-session.sh — archive and clear an OpenShell agent's live session.
#
#   bash ops/reset-agent-session.sh <agent> --check     # report only (default)
#   bash ops/reset-agent-session.sh <agent> --commit    # archive + truncate
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# An OpenClaw session accumulates history until it exceeds the model's context
# window. When it does, the failure is TOTAL and SILENT: every heartbeat dies in
# precheck before the model emits a single token, and auto-compaction cannot
# recover — compaction is itself a model call carrying the same oversized
# prompt, so it overflows too.
#
# Measured on cecat 2026-09-07: 116,708 estimated tokens against a 131,072
# window, 40 consecutive dead heartbeats over ~14 hours, `compactionTokens`
# identical on all 52 recovery attempts. The agent kept answering Slack the
# whole time, so nothing looked wrong.
#
# The legacy stack prevented this with shared/scripts/cron/reset-sessions.sh,
# running 4x/day against `docker exec openclaw-gateway`. That script targets the
# LEGACY container and does nothing on OpenShell. This is the manual,
# single-agent equivalent; the scheduled port is a separate piece of work.
#
# ── WHICH FILE MATTERS ──────────────────────────────────────────────────────
#
# Each session is two files:
#   <id>.jsonl              the TRANSCRIPT — what the model actually replays.
#   <id>.trajectory.jsonl   an observability sidecar, ~4x larger.
#
# **Only the transcript drives context overflow.** The legacy script thresholded
# on byte size, so it mostly archived the sidecar — reclaiming disk without
# reducing what the model sees. Do not repeat that mistake: this script clears
# the transcript and leaves the sidecar for forensics.
#
# ── C-0b: THIS OVERWRITES. CHARLIE APPROVES. ────────────────────────────────
#
# --commit archives to a host path first, verifies the copy byte-for-byte, and
# only then clears the original. Nothing is removed: the live file is RENAMED to
# <id>.jsonl.reset.<ts> in place (matching what the legacy tooling did) and a
# fresh empty transcript is created. Recovery is a mv.
set -uo pipefail

AGENT="${1:-}"
MODE="${2:---check}"

case "$AGENT" in
    cecat) PORT=8090 ;;
    luoji) PORT=8091 ;;
    # gandalf is a Hermes agent on the :8080 plane — C-2, never operated on.
    *) echo "Usage: $0 <cecat|luoji> [--check|--commit]" >&2; exit 1 ;;
esac

case "$MODE" in
    --check)  ACT=check ;;
    --commit) ACT=commit ;;
    *) echo "Usage: $0 <cecat|luoji> [--check|--commit]" >&2; exit 1 ;;
esac

MNT="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT"
SESSIONS="$MNT/.openclaw/agents/main/sessions"
ARCHIVE_DIR="$HOME/code/Spark-OpenClaw/shared/session-archives/$(date -u +%Y-%m-%d)"
LOG_FILE="$HOME/code/Spark-OpenClaw/shared/logs/sessions-reset.log"
NOW="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

if ! mountpoint -q "$MNT" 2>/dev/null && [ ! -d "$SESSIONS" ]; then
    echo "FAIL: $SESSIONS unreachable — is the sshfs mount up?" >&2
    echo "      bash ops/mount-agent-filespaces.sh --check" >&2
    exit 1
fi

# The live transcript is the most recently modified *.jsonl that is not an
# already-reset file, not the sessions.json registry, and not a warmup session.
LIVE=""
while IFS= read -r f; do
    case "$(basename "$f")" in
        sessions.json|*.reset.*|nemoclaw-onboard-warmup-*) continue ;;
    esac
    LIVE="$f"; break
done < <(ls -t "$SESSIONS"/*.jsonl 2>/dev/null)

if [ -z "$LIVE" ]; then
    echo "FAIL: no live transcript found in $SESSIONS" >&2
    exit 1
fi

ID="$(basename "$LIVE" .jsonl)"
BYTES="$(stat -c %s "$LIVE")"
LINES="$(wc -l < "$LIVE")"

echo "════════════════════════════════════════════"
echo "  $AGENT (plane $PORT)"
echo "════════════════════════════════════════════"
echo "  session:    $ID"
echo "  transcript: $LIVE"
echo "  size:       $BYTES bytes / $LINES lines"
echo "  sidecar:    $(stat -c %s "$SESSIONS/$ID.trajectory.jsonl" 2>/dev/null || echo n/a) bytes (left in place)"
echo

if [ "$ACT" = check ]; then
    echo "  --check only. Nothing modified."
    echo "  To apply:  bash ops/reset-agent-session.sh $AGENT --commit"
    exit 0
fi

mkdir -p "$ARCHIVE_DIR" "$(dirname "$LOG_FILE")"
ARCHIVE_PATH="$ARCHIVE_DIR/${AGENT}_${ID}.jsonl"

# 1. Archive to the host, then verify the copy before touching the original.
if ! cp "$LIVE" "$ARCHIVE_PATH"; then
    echo "FAIL: could not archive to $ARCHIVE_PATH — nothing changed." >&2
    exit 1
fi
if ! cmp -s "$LIVE" "$ARCHIVE_PATH"; then
    echo "FAIL: archive does not match source — nothing changed." >&2
    exit 1
fi
echo "  ARCHIVED -> $ARCHIVE_PATH ($(stat -c %s "$ARCHIVE_PATH") bytes, verified)"

# 2. Rename the live transcript in place. Not a delete — recovery is a mv.
RESET_PATH="$SESSIONS/$ID.jsonl.reset.$NOW"
if ! mv "$LIVE" "$RESET_PATH"; then
    echo "FAIL: could not rename live transcript. Archive kept at $ARCHIVE_PATH." >&2
    exit 1
fi
echo "  RENAMED  -> $(basename "$RESET_PATH")"

# 3. Recreate an empty transcript owned by the sandbox user. The gateway errors
#    on a missing session path, so the file must exist.
: > "$LIVE"
chmod --reference="$RESET_PATH" "$LIVE" 2>/dev/null || chmod 644 "$LIVE"
echo "  CREATED  -> empty $(basename "$LIVE")"

echo "$NOW | $AGENT | $ID | ${BYTES}B/${LINES}L | archived=$ARCHIVE_PATH | context-overflow reset" >> "$LOG_FILE"

echo
echo "  DONE. Next heartbeat starts from an empty transcript and re-reads"
echo "  SOUL.md / HEARTBEAT.md / memory files fresh."
echo
echo "  VERIFY (do not trust this script's own output):"
echo "    watch the next tick land in"
echo "      $MNT/.openclaw/logs/gateway-persistent.log"
echo "    and confirm promptError is absent from the newest model.completed in"
echo "      $SESSIONS/$ID.trajectory.jsonl"
