#!/usr/bin/env bash
# check-pipeline-liveness.sh — detect ACTIVE-BUT-IDLE components.
#
#   bash ops/check-pipeline-liveness.sh            # report; exit 1 if anything stale
#   bash ops/check-pipeline-liveness.sh --quiet    # print ONLY problems (for cron)
#
# ── THE FAILURE THIS CATCHES, AND WHY NOTHING ELSE DOES ─────────────────────
#
# Every existing check on this box answers "is the process running?" None answer
# "is it still doing anything?" That gap has now produced FOUR silent outages:
#
#   * bind mounts lost           — agents answered Slack for 4 weeks, runbooks inert
#   * /shared frozen copy        — escalations written to a dead drop for 2 days
#   * cecat context overflow     — 40 dead heartbeats, still "healthy"
#   * falda-tap-gandalf          — unit ACTIVE, last write 2026-09-02,
#                                  distiller watermark frozen 6 days (found 09-08)
#
# In every case `systemctl is-active` said active and `start-all.sh` said green.
# `run-stack-health.sh` cannot help either — by its own header it "REPAIRS WHILE
# IT CHECKS", so a component that dies and is silently restarted every 6 hours
# looks identical to one that never fails.
#
# **This script never repairs and never restarts.** It only asks: has this thing
# produced output recently? A stale watermark is the signal; the process state is
# irrelevant and deliberately not consulted as evidence of health.
#
# ── ON THRESHOLDS ───────────────────────────────────────────────────────────
#
# Each threshold is set well above the component's natural cadence so ordinary
# quiet does not page anyone, but far below "nobody would notice". They are
# judgement calls, not measurements — tune them, but keep a comment saying why.
#
# luoji is EXEMPT from heartbeat staleness outside 08:00-22:00 America/Chicago:
# he has `activeHours` and an out-of-hours gap is CORRECT. Getting this wrong
# already produced one false alarm.
#
# ── C-2 ─────────────────────────────────────────────────────────────────────
#
# Gandalf's FALDA tenant is REPORTED here because a stale tap is worth knowing
# about, but this script never operates on his plane — read-only, always.
set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

NOW=$(date +%s)
PROBLEMS=0
CHECKED=0

say()  { [ "$QUIET" -eq 1 ] || echo "$*"; }
warn() { echo "$*"; PROBLEMS=$((PROBLEMS + 1)); }

# age_of <file> -> seconds since mtime, or empty if missing
age_of() {
    [ -e "$1" ] || { echo ""; return; }
    local m; m=$(stat -c %Y "$1" 2>/dev/null) || { echo ""; return; }
    echo $(( NOW - m ))
}

human() {
    local s="$1"
    if   [ "$s" -lt 3600 ];  then echo "$((s / 60))m"
    elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"
    else echo "$((s / 86400))d"; fi
}

# check_fresh <label> <path> <max_seconds> <what-it-means-if-stale>
check_fresh() {
    local label="$1" path="$2" max="$3" meaning="$4"
    CHECKED=$((CHECKED + 1))
    local age; age=$(age_of "$path")
    if [ -z "$age" ]; then
        warn "MISSING  $label — $path does not exist. $meaning"
        return
    fi
    if [ "$age" -gt "$max" ]; then
        warn "STALE    $label — last activity $(human "$age") ago (limit $(human "$max")). $meaning"
    else
        say  "ok       $label — $(human "$age") ago"
    fi
}

# check_json_ts <label> <json> <key> <max_seconds> <meaning>
# Reads an ISO-8601 timestamp from a JSON field. A watermark that stops moving
# while the file itself keeps being rewritten is the subtlest form of this bug —
# falda-tap-gandalf failed exactly this way.
check_json_ts() {
    local label="$1" json="$2" key="$3" max="$4" meaning="$5"
    CHECKED=$((CHECKED + 1))
    [ -f "$json" ] || { warn "MISSING  $label — $json absent. $meaning"; return; }
    local ts age
    ts=$(python3 -c "
import json,sys,datetime
try:
    v=json.load(open(sys.argv[1])).get(sys.argv[2])
    if not v: print(''); raise SystemExit
    s=str(v).replace('Z','+00:00')
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    print('')
" "$json" "$key" 2>/dev/null)
    if [ -z "$ts" ]; then
        warn "UNREADABLE $label — could not parse '$key' in $json. $meaning"
        return
    fi
    age=$(( NOW - ts ))
    if [ "$age" -gt "$max" ]; then
        warn "STALE    $label — watermark $(human "$age") old (limit $(human "$max")). $meaning"
    else
        say  "ok       $label — watermark $(human "$age") old"
    fi
}

say "════════════════════════════════════════════════════════════════"
say "  pipeline liveness — did these components DO anything recently?"
say "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "════════════════════════════════════════════════════════════════"
say

# ── Agent heartbeats ────────────────────────────────────────────────────────
# The gateway log is appended on every tick. Cadence 15m; 90m = 6 missed ticks.
say "── agent heartbeats ──"
check_fresh "cecat heartbeat" \
    "$HOME/.nemoclaw/gateways/8090/mounts/cecat/.openclaw/logs/gateway-persistent.log" \
    5400 "Heartbeat has stopped ticking. She will still answer Slack. Check for context overflow: bash ops/reset-sessions-openshell.sh --check"

# luoji: activeHours 08:00-22:00 America/Chicago. Out of hours, silence is correct.
LUOJI_HOUR=$(TZ=America/Chicago date +%-H)
if [ "$LUOJI_HOUR" -ge 8 ] && [ "$LUOJI_HOUR" -lt 22 ]; then
    check_fresh "luoji heartbeat" \
        "$HOME/.nemoclaw/gateways/8091/mounts/luoji/.openclaw/logs/gateway-persistent.log" \
        5400 "Heartbeat has stopped ticking during his active hours."
else
    say "skip     luoji heartbeat — outside activeHours (08:00-22:00 America/Chicago); silence is CORRECT"
fi

# ── FALDA memory pipeline ───────────────────────────────────────────────────
#
# ⚠ AN IDLE TAP IS NOT A BROKEN TAP — this check cried wolf on its first run.
#
# 2026-09-08: this script reported falda-tap-gandalf "STALE 5d" and the
# supervisor wrote it up as a six-day silent failure. It was not. Charlie
# messaged Gandalf and the tap mirrored the exchange **within seconds**
# (checkpoint 122891 -> 138712). Nobody had talked to Gandalf since 09-02, so
# the tap correctly mirrored nothing. Six days of SILENCE, not six days of
# FAILURE — and the distinction is the whole point of this file.
#
# So: these taps are demand-driven. A quiet agent produces a quiet tap, and no
# mtime threshold can separate that from a wedged one. **7 days is a
# "somebody should look" nudge, not an alarm** — and the message says so, in
# the words a reader needs to avoid repeating the supervisor's mistake.
#
# The distiller's `last_ts` lags its own log by design (L1 batches), so it is
# checked on log mtime rather than on the watermark: on 09-08 the watermark
# read 6 days old while the process was writing scenes the same hour.
#
# What WOULD prove a wedged tap: the process not logging a successful poll.
# The taps do not log zero-row polls, so that check cannot be built from here —
# it needs a heartbeat line in falda_tap_*.py. Filed, not built.
say
say "── FALDA memory pipeline (demand-driven — quiet != broken) ──"
check_fresh "falda-tap-luoji"         "$HOME/.falda/tap_luoji.log"        604800 "No turns mirrored in 7d. Probably just quiet — confirm by messaging the agent and watching this log."
check_fresh "falda-distiller-luoji"   "$HOME/.falda/distiller-luoji.log"  604800 "Distiller has logged nothing in 7d. Check after confirming the tap is fed."
# C-2: reported, never operated on.
check_fresh "falda-tap-gandalf"       "$HOME/.falda/tap_gandalf.log"      604800 "No turns mirrored in 7d (Hermes side — report only). Probably just quiet; message Gandalf and watch this log before assuming a fault."
check_fresh "falda-distiller-gandalf" "$HOME/.falda/distiller-gandalf.log" 604800 "Distiller has logged nothing in 7d (Hermes side — report only)."

# ── Host cron pipelines ─────────────────────────────────────────────────────
# send-slack runs every 5m but only logs when it SENDS, so a quiet queue is
# normal — 7d catches "the drain has been broken for a week", not "no traffic".
say
say "── host cron pipelines ──"
check_fresh "slack drain"    "$HOME/code/spark-ai-agents/shared/logs/slack-posts.log" 604800 "No Slack message sent in a week. Agent escalations may be stranded."
# NOT todos-cron.log — that is the crontab's stderr sink and is EMPTY on a
# healthy system (last write Jun 16). Watching it produced an immediate false
# positive: "84d stale" on a pipeline that was working perfectly. todos.log is
# what check-todos.sh actually writes on every run.
check_fresh "todo promoter"  "$HOME/code/spark-ai-agents/shared/logs/todos.log"        21600 "check-todos.sh has not run in 6h (cadence 5m). Scheduled work is not being promoted."

say
say "════════════════════════════════════════════════════════════════"
if [ "$PROBLEMS" -eq 0 ]; then
    say "  PASS — $CHECKED checks, everything has produced output recently"
    say "════════════════════════════════════════════════════════════════"
    exit 0
fi
echo "  $PROBLEMS of $CHECKED checks STALE or MISSING"
echo "  (a stale component is usually still 'active' — that is the point)"
echo "════════════════════════════════════════════════════════════════"
exit 1
