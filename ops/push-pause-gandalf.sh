#!/usr/bin/env bash
# push-pause-gandalf.sh — make the kill switch reach Gandalf.
#
#   bash ops/push-pause-gandalf.sh            # reconcile his cron to host intent
#   bash ops/push-pause-gandalf.sh --check    # report only, change nothing
#
# Exit 0 = his plane matches host intent. Non-zero = it does not, or an error.
#
# THE GAP THIS CLOSES
#
# `pause.sh global` says "global" and stops two of three agents. CeCat and
# LuoJi get a mirrored sentinel file (ops/push-pause-sentinels.sh, the OpenClaw
# half of this same job). Gandalf got nothing — he kept running while an
# operator believed the box was stopped. That is the single worst outcome here,
# so everything below is built to make the TRUE state visible rather than
# merely to make the pause work.
#
# MECHANISM — native `hermes cron pause`, not a sentinel file
#
# Gandalf's autonomous work IS Hermes cron, so the scheduler is the thing that
# should refuse to fire. Three of his five jobs are LLM prompt jobs; a sentinel
# checked *by the prompt* would wake the model every 5 minutes to read a file
# and decide to do nothing — advisory, and it burns tokens while paused. A
# paused job is the scheduler declining to start. There is no model in the loop
# to disobey. (Design: Claude-Code-Supervisor/tasks/PLAN-gandalf-kill-switch.md
# §1; principle: docs/COMPARISON-…-Hermes-NemoClaw.md L14.)
#
# The host sentinel directory stays the single source of truth for all three
# agents. This script only ever mirrors it inward. It never invents a pause.
#
# REBOOT BEHAVIOUR — this half fails CLOSED, the OpenClaw half fails OPEN
#
# `hermes cron pause` persists to /sandbox/.hermes/cron/jobs.json in the
# container's writable layer, so a pause survives a gateway restart and a host
# reboot. The OpenClaw sentinel does not (the sshfs mount and /shared symlink
# die with the reboot). The two planes therefore fail in OPPOSITE directions.
# Do not "fix" this one to match — a kill switch should err toward stopped.
# What makes the asymmetry safe is that the checker can always tell you which
# state each plane is actually in.
#
# A rebuild DOES clear it: apply-cron.sh recreates the jobs unpaused. That is
# why ops/post-rebuild.sh must call this script AFTER apply-cron.sh.
#
# WHY IT READS JSON AND WRITES VIA THE CLI
#
# The authoritative paused/running value is `state` (and `enabled`) per job in
# jobs.json. In `hermes cron list` the marker is a BRACKET on the job's header
# line — `  <id> [active]` / `[paused]` — not a `Key: value` field, so a parser
# looking for a `Paused:` field finds nothing and silently reports everything
# running. Read the JSON; use the CLI only to make changes.
#
# Every in-sandbox call goes through sb_exec. Do NOT hand-roll `docker exec`:
# sb_exec sets HERMES_HOME=/sandbox/.hermes, without which a bare `hermes` dies
# with PermissionError on /root/.hermes/.env because HOME resolves to /root.
set -u

. "$(dirname "$0")/_lib.sh"

# _lib.sh gives info/warn/note/fail. It has no non-fatal red printer, and this
# script needs one: several failures must be shouted and still fall through to
# a summary line before exiting. Defined locally rather than added to the
# shared lib, which is out of scope for this change.
bad() { printf "${RED}[✗]${NC} %s\n" "$*" >&2; }

CHECK=false
case "${1:-}" in
    "")       ;;
    --check)  CHECK=true ;;
    *)        fail "Unknown argument: $1 (usage: $(basename "$0") [--check])" ;;
esac

STATE="$HOME/code/Spark-OpenClaw/shared/state"

# Gandalf's five cron jobs, by NAME. Names are stable; the hex job IDs are
# regenerated whenever apply-cron.sh recreates jobs after a rebuild, so a
# reconciler keyed on IDs would break exactly when it is needed most.
# `hermes cron pause` resolves a ref as ID-then-case-insensitive-name.
ALL_JOBS="daily-briefing inbox-triage outbox-send heartbeat outbox-pending-guard"

# Which jobs each host sentinel pauses. See PLAN §2.
#   PAUSE.global          -> all five
#   PAUSE.agent.gandalf   -> all five
#   PAUSE.email           -> outbox-send only
#   PAUSE.slack           -> NONE. Deliberately does not pause `heartbeat`:
#                            heartbeat only DMs on failure, and under a
#                            Slack-scoped pause that is the one message still
#                            wanted. The host-side outbox-processor.sh guard
#                            covers Gandalf's other scheduled Slack output.
#   PAUSE.agent.cecat|luoji -> none, not his.

echo "════════════════════════════════════════════"
echo "  Kill switch -> Gandalf (Hermes cron)"
echo "════════════════════════════════════════════"
echo "  host source : $STATE"
echo "  plane       : hermes cron, via sb_exec"
$CHECK && echo "  mode        : --check (nothing will be changed)"
echo

# ── Host intent ─────────────────────────────────────────────────────────────
#
# A missing or unreadable state directory is a HARD error, never "nothing is
# paused". If we cannot read host intent we cannot tell paused from unpaused,
# and guessing in either direction is the failure this script exists to prevent.
[ -d "$STATE" ] || fail "Host state dir does not exist: $STATE — cannot read pause intent, refusing to guess."
[ -r "$STATE" ] && [ -x "$STATE" ] || fail "Host state dir is not readable: $STATE — cannot read pause intent, refusing to guess."

SENTINELS=""          # which PAUSE.* files the host has, for display
WANT_PAUSED=""        # which job names should be paused
REASON=""             # displayed to the operator; the CLI cannot store it (see do_pause)

add_want() { case " $WANT_PAUSED " in *" $1 "*) ;; *) WANT_PAUSED="$WANT_PAUSED $1" ;; esac; }

# Reason precedence follows scope precedence: global > agent > email.
read_reason() { sed -n 's/^reason:[[:space:]]*//p' "$1" 2>/dev/null | head -1; }

if [ -f "$STATE/PAUSE.global" ]; then
    SENTINELS="$SENTINELS PAUSE.global"
    for j in $ALL_JOBS; do add_want "$j"; done
    [ -n "$REASON" ] || REASON=$(read_reason "$STATE/PAUSE.global")
fi
if [ -f "$STATE/PAUSE.agent.gandalf" ]; then
    SENTINELS="$SENTINELS PAUSE.agent.gandalf"
    for j in $ALL_JOBS; do add_want "$j"; done
    [ -n "$REASON" ] || REASON=$(read_reason "$STATE/PAUSE.agent.gandalf")
fi
if [ -f "$STATE/PAUSE.email" ]; then
    SENTINELS="$SENTINELS PAUSE.email"
    add_want outbox-send
    [ -n "$REASON" ] || REASON=$(read_reason "$STATE/PAUSE.email")
fi
# PAUSE.slack is read only so it shows in the "host wants" display; it maps to
# no in-sandbox job. Recording it keeps the operator from reading its absence
# from this line as "the script did not see it".
[ -f "$STATE/PAUSE.slack" ] && SENTINELS="$SENTINELS PAUSE.slack(no cron effect)"

WANT_PAUSED="${WANT_PAUSED# }"
SENTINELS="${SENTINELS# }"

# ── Plane reality ───────────────────────────────────────────────────────────

if ! CON=$(gandalf_container); then
    # gandalf_container has already printed its own reason to stderr.
    printf "  %-7s host wants:[ %s ]  plane: NO RUNNING SANDBOX — state UNKNOWN\n" \
        "gandalf" "${SENTINELS:-none}"
    exit 1
fi
note "container: $CON"

JOBS_JSON=$(sb_exec cat /sandbox/.hermes/cron/jobs.json 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    printf '%s\n' "$JOBS_JSON" | sed 's/^/      /'
    fail "Could not read /sandbox/.hermes/cron/jobs.json (rc=$RC). Gandalf's pause state is UNKNOWN."
fi

# Parse on the host. Tolerates the three plausible shapes of jobs.json (a bare
# list, {"jobs": [...]}, or an id->job map) because only the field semantics
# are established, not the envelope.
PARSE_PY=$(cat <<'PYEOF'
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    sys.stderr.write("jobs.json is not valid JSON: %s\n" % e)
    sys.exit(2)
if isinstance(d, list):
    jobs = d
elif isinstance(d, dict):
    if isinstance(d.get("jobs"), list):
        jobs = d["jobs"]
    elif isinstance(d.get("jobs"), dict):
        jobs = list(d["jobs"].values())
    else:
        jobs = [v for v in d.values() if isinstance(v, dict)]
else:
    sys.stderr.write("jobs.json has an unexpected top-level type: %s\n" % type(d).__name__)
    sys.exit(2)
for j in jobs:
    if not isinstance(j, dict):
        continue
    name = str(j.get("name") or "").strip()
    if not name:
        continue
    # Same derivation the Hermes CLI uses to render [active]/[paused].
    state = j.get("state") or ("scheduled" if j.get("enabled", True) else "paused")
    print("%s\t%s" % (name, "paused" if state == "paused" else "running"))
PYEOF
)

read_plane() {
    printf '%s' "$JOBS_JSON" | python3 -c "$PARSE_PY"
}

TSV=$(read_plane)
RC=$?
[ "$RC" -eq 0 ] || fail "Could not parse jobs.json (rc=$RC). Gandalf's pause state is UNKNOWN."

# ── Compare ─────────────────────────────────────────────────────────────────
#
# The counts are part of the assertion. Zero jobs read is a FAILURE (the
# container is unreachable or the parse broke), never "nothing to pause".

job_state() { printf '%s\n' "$TSV" | awk -F'\t' -v n="$1" '$1==n {print $2; found=1} END{if(!found) print "absent"}'; }

evaluate() {
    # Sets: PAUSED_LIST RUNNING_LIST ABSENT_LIST UNKNOWN_LIST TO_PAUSE TO_RESUME
    #       FOUND_N PAUSED_N MISMATCH
    PAUSED_LIST=""; RUNNING_LIST=""; ABSENT_LIST=""; UNKNOWN_LIST=""
    TO_PAUSE=""; TO_RESUME=""
    FOUND_N=0; PAUSED_N=0; MISMATCH=0

    local j st want
    for j in $ALL_JOBS; do
        st=$(job_state "$j")
        case " $WANT_PAUSED " in *" $j "*) want=paused ;; *) want=running ;; esac
        case "$st" in
            paused)
                FOUND_N=$((FOUND_N + 1)); PAUSED_N=$((PAUSED_N + 1))
                PAUSED_LIST="$PAUSED_LIST $j"
                # Paused while the host wants it running is an agent stopped
                # while believed running — as much a failure as the inverse.
                [ "$want" = running ] && { TO_RESUME="$TO_RESUME $j"; MISMATCH=$((MISMATCH + 1)); }
                ;;
            running)
                FOUND_N=$((FOUND_N + 1))
                RUNNING_LIST="$RUNNING_LIST $j"
                [ "$want" = paused ] && { TO_PAUSE="$TO_PAUSE $j"; MISMATCH=$((MISMATCH + 1)); }
                ;;
            *)
                # Not in jobs.json at all. Not running, so it does not defeat a
                # pause, but it IS drift worth seeing (a rebuild before
                # apply-cron.sh looks exactly like this).
                ABSENT_LIST="$ABSENT_LIST $j"
                ;;
        esac
    done

    # Any job on his plane that this script does not know about is an unpaused
    # hole in the kill switch. Under a whole-agent pause that is a mismatch,
    # because "all his scheduled work is stopped" would be a false claim.
    local k
    for k in $(printf '%s\n' "$TSV" | awk -F'\t' '{print $1}'); do
        case " $ALL_JOBS " in
            *" $k "*) ;;
            *) UNKNOWN_LIST="$UNKNOWN_LIST $k" ;;
        esac
    done
}

evaluate

WHOLE_AGENT_PAUSE=false
case "$SENTINELS" in *PAUSE.global*|*PAUSE.agent.gandalf*) WHOLE_AGENT_PAUSE=true ;; esac

report_line() {
    printf "  %-7s host wants:[ %s ]  cron paused %d/%d [%s ]\n" \
        "gandalf" "${SENTINELS:-none}" "$PAUSED_N" "$FOUND_N" "${PAUSED_LIST:- none}"
}

# ── --check: report and stop ────────────────────────────────────────────────

if $CHECK; then
    report_line
    [ -n "$ABSENT_LIST" ]  && warn "  jobs declared here but NOT on his plane:${ABSENT_LIST} (rebuild without apply-cron.sh?)"
    [ -n "$UNKNOWN_LIST" ] && warn "  jobs on his plane this script does not manage:${UNKNOWN_LIST}"
    if [ "$FOUND_N" -eq 0 ]; then
        bad "  gandalf FAIL — zero known jobs read from jobs.json. This is a broken read or a broken parse, NOT 'nothing to pause'."
        exit 1
    fi
    if [ "$MISMATCH" -eq 0 ]; then
        if $WHOLE_AGENT_PAUSE && [ -n "$UNKNOWN_LIST" ]; then
            warn "  gandalf OUT OF SYNC — whole-agent pause, but unmanaged job(s) still scheduled:${UNKNOWN_LIST}"
            exit 1
        fi
        info "  gandalf IN SYNC"
        exit 0
    fi
    [ -n "$TO_PAUSE" ]  && warn "  should be PAUSED but is running:${TO_PAUSE}  (working while believed stopped)"
    [ -n "$TO_RESUME" ] && warn "  should be RUNNING but is paused:${TO_RESUME}  (stopped while believed running)"
    bad "  gandalf OUT OF SYNC — $MISMATCH job(s) wrong. Reconcile with: bash ops/$(basename "$0")"
    exit 1
fi

# ── Reconcile ───────────────────────────────────────────────────────────────

if [ "$FOUND_N" -eq 0 ]; then
    fail "Zero known jobs read from jobs.json — refusing to act. This is a broken read or parse, NOT 'nothing to pause'."
fi

if [ "$MISMATCH" -eq 0 ]; then
    report_line
    [ -n "$ABSENT_LIST" ]  && warn "  jobs declared here but NOT on his plane:${ABSENT_LIST}"
    [ -n "$UNKNOWN_LIST" ] && warn "  jobs on his plane this script does not manage:${UNKNOWN_LIST}"
    info "  gandalf already in sync — no action"
    if $WHOLE_AGENT_PAUSE && [ -n "$UNKNOWN_LIST" ]; then
        bad "  but a whole-agent pause is set and unmanaged job(s) are still scheduled:${UNKNOWN_LIST}"
        exit 1
    fi
    exit 0
fi

# THE CLI EXPOSES NO --reason FLAG. Measured 2026-09-17 against the installed
# build: `usage: hermes cron pause [-h] job_id`, nothing else.
#
# The underlying pause_job() (/opt/hermes/cron/jobs.py:742) DOES take a reason
# and writes a first-class `paused_reason` field, so the capability exists — the
# CLI simply does not surface it. An earlier draft passed `--reason` with a
# fallback to a bare pause; that branch would have failed on EVERY pause and
# warned on every one, so it is removed rather than left as permanently-dead
# code that looks live. If a future Hermes exposes the flag, add it here.
#
# The reason is not lost: it lives in the host sentinel file, which is the
# single source of truth for all three agents.
#
# Output and exit code are kept — a pause that failed must never look like a
# pause that worked (C-20).
do_pause() {
    local job="$1" out rc
    out=$(sb_exec /usr/local/bin/hermes cron pause "$job" 2>&1); rc=$?
    printf '%s\n' "$out" | sed 's/^/        /'
    return "$rc"
}

do_resume() {
    local job="$1" out rc
    out=$(sb_exec /usr/local/bin/hermes cron resume "$job" 2>&1); rc=$?
    printf '%s\n' "$out" | sed 's/^/        /'
    return "$rc"
}

for j in $TO_PAUSE; do
    note "  pausing $j${REASON:+ (reason: $REASON)}"
    do_pause "$j" || bad "    hermes cron pause $j FAILED"
done
for j in $TO_RESUME; do
    note "  resuming $j"
    do_resume "$j" || bad "    hermes cron resume $j FAILED"
done

# ── Re-read and verify ──────────────────────────────────────────────────────
#
# The exit code is decided by a fresh measurement, not by whether the commands
# above appeared to succeed. A verdict derived from intent is how a half-landed
# pause gets reported as a whole one.

echo
JOBS_JSON=$(sb_exec cat /sandbox/.hermes/cron/jobs.json 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    printf '%s\n' "$JOBS_JSON" | sed 's/^/      /'
    fail "Re-read of jobs.json failed after reconciling (rc=$RC). Gandalf's pause state is UNKNOWN."
fi
TSV=$(read_plane) || fail "Re-parse of jobs.json failed after reconciling. Gandalf's pause state is UNKNOWN."

evaluate
report_line
[ -n "$ABSENT_LIST" ]  && warn "  jobs declared here but NOT on his plane:${ABSENT_LIST}"
[ -n "$UNKNOWN_LIST" ] && warn "  jobs on his plane this script does not manage:${UNKNOWN_LIST}"

if [ "$FOUND_N" -eq 0 ]; then
    bad "  gandalf FAIL — zero known jobs on the re-read."
    exit 1
fi
if [ "$MISMATCH" -ne 0 ]; then
    [ -n "$TO_PAUSE" ]  && bad "  still running but should be paused:${TO_PAUSE}"
    [ -n "$TO_RESUME" ] && bad "  still paused but should be running:${TO_RESUME}"
    bad "  gandalf OUT OF SYNC after reconciling — $MISMATCH job(s) wrong."
    exit 1
fi
if $WHOLE_AGENT_PAUSE && [ -n "$UNKNOWN_LIST" ]; then
    bad "  whole-agent pause is set, but unmanaged job(s) are still scheduled:${UNKNOWN_LIST}"
    exit 1
fi
info "  gandalf IN SYNC"
exit 0
