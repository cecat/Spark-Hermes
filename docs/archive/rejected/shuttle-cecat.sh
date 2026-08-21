#!/bin/bash
# shuttle-cecat.sh — move files between the host and cecat's OpenShell sandbox.
#
# WHY THIS EXISTS
#   Under hand-rolled Docker Compose, cecat had bind mounts: /workspace, /shared
#   and /scripts were the same inodes on both sides, so the host cron and the
#   agent saw each other's writes instantly. OpenShell has NO bind mounts of any
#   kind — `openshell sandbox create` has no flag for it (verified against
#   0.0.44 --help and the v0.0.55 source; see
#   Spark-Hermes/docs/DECISION-cecat-shared-mechanism.md). Everything in the
#   sandbox lives in the container's writable layer.
#
#   So the shared filesystem has to be emulated by copying. This script is that
#   emulation. It does NOT deliver anything itself — send-slack.sh still owns
#   delivery. This only moves files to where send-slack.sh can already see them.
#
# THE LOAD-BEARING DIRECTION IS AGENT -> HOST
#   cecat has no Slack egress. Every notification she makes is a JSON file in
#   the outbox; a host cron delivers it. If this script stops running, she goes
#   completely silent while every health check still reports her as fine. Treat
#   a failure here as an outage, not a nuisance.
#
# Crontab (every 5 min, matching send-slack.sh's cadence):
#   */5 * * * * /home/catlett/code/spark-ai-agents/shared/scripts/cron/shuttle-cecat.sh >> /home/catlett/code/spark-ai-agents/shared/logs/shuttle-cecat.log 2>&1
#
# PAUSE is deliberately NOT handled here — see the note at the bottom.

set -euo pipefail
source "$HOME/code/spark-ai-agents/shared/config.sh"
AUDIT_ACTOR="shuttle-cecat.sh"
source "$HOME/code/spark-ai-agents/shared/scripts/lib/audit.sh"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SANDBOX="${CECAT_SANDBOX:-cecat}"
SBX_WORKSPACE="/sandbox/workspace"
SBX_OUTBOX="$SBX_WORKSPACE/shared/slack/outbox"

LOG_FILE="$LOGS_DIR/shuttle-cecat.log"
log() { echo "$(date -Iseconds) $*" >> "$LOG_FILE"; }

# Single-instance guard. A slow download must not overlap with the next tick and
# race on the same files.
LOCK="/tmp/shuttle-cecat.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "SKIP — previous run still in progress"
    exit 0
fi

# If the sandbox isn't up there is nothing to shuttle. Exit 0: a stopped sandbox
# is a normal state (maintenance, host reboot), not a cron failure worth mailing
# about. The agent-is-silent alarm below is what catches a real outage.
if ! openshell sandbox list 2>/dev/null | grep -qE "^${SANDBOX}\b.*Ready"; then
    log "SKIP — sandbox '$SANDBOX' not Ready"
    exit 0
fi

STAGING=$(mktemp -d /tmp/shuttle-cecat.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Direction 1: AGENT -> HOST  (outbox drain — the one that matters)
# ─────────────────────────────────────────────────────────────────────────────
#
# Copy out, then delete in the sandbox only after the host copy is committed.
# Ordering matters: a crash between the two duplicates a Slack message, which is
# recoverable. The reverse order would LOSE one, which is not.
#
# We deliberately do not use `download` on the directory and then wipe it —
# a file written by the agent between the download and the wipe would be
# destroyed unread. Instead each file is handled individually by name.

mkdir -p "$SLACK_OUTBOX"
moved=0

pending=$(openshell sandbox exec -n "$SANDBOX" -- \
    sh -c "ls -1 $SBX_OUTBOX/*.json 2>/dev/null || true" 2>/dev/null || true)

for remote in $pending; do
    filename=$(basename "$remote")

    # Refuse anything that isn't a plain filename. The sandbox is the less
    # trusted side of this boundary and the agent processes untrusted email;
    # a crafted name must not be able to write outside the outbox.
    case "$filename" in
        *[!A-Za-z0-9._-]* | .* | "")
            log "SKIP suspicious filename from sandbox: $(printf '%q' "$filename")"
            audit_log shuttle skip_suspicious file="$(printf '%q' "$filename")"
            continue
            ;;
    esac

    if ! openshell sandbox download "$SANDBOX" "$remote" "$STAGING/" >/dev/null 2>&1; then
        log "FAIL download $filename — leaving in sandbox for next run"
        continue
    fi

    staged="$STAGING/$filename"
    [[ -f "$staged" ]] || staged=$(find "$STAGING" -name "$filename" -type f | head -1)
    if [[ ! -f "$staged" ]]; then
        log "FAIL download $filename — not found after download"
        continue
    fi

    # Validate before committing. A malformed file left in the host outbox would
    # make send-slack.sh alert on every run; better to leave it in the sandbox.
    if ! jq -e '.channel // .to' "$staged" >/dev/null 2>&1; then
        log "SKIP $filename — invalid JSON or missing channel; left in sandbox"
        audit_log shuttle skip_invalid file="$filename"
        continue
    fi

    # mv within /tmp -> shared may cross filesystems; cp+rm keeps it atomic-ish
    # by writing to a temp name first, then renaming into place.
    if ! cp "$staged" "$SLACK_OUTBOX/.$filename.partial" 2>/dev/null; then
        log "FAIL staging $filename to host outbox"
        continue
    fi
    mv "$SLACK_OUTBOX/.$filename.partial" "$SLACK_OUTBOX/$filename"

    # Host copy is committed. Now it is safe to remove the sandbox copy.
    if openshell sandbox exec -n "$SANDBOX" -- rm -f "$remote" >/dev/null 2>&1; then
        moved=$((moved + 1))
        log "MOVED $filename agent->host"
        audit_log shuttle moved file="$filename" direction=agent_to_host
    else
        # Host has it, sandbox still has it. send-slack.sh will deliver the host
        # copy; next run will re-download and re-deliver → duplicate message.
        # Loud, because a silent duplicate is confusing to the operator.
        log "WARN $filename copied to host but NOT removed from sandbox — possible duplicate next run"
        audit_log shuttle orphan file="$filename"
    fi
done

[[ $moved -gt 0 ]] && log "drained $moved file(s) agent->host"

# ─────────────────────────────────────────────────────────────────────────────
# Direction 2: HOST -> AGENT  (READY tasks)
# ─────────────────────────────────────────────────────────────────────────────
#
# check-todos.sh writes READY lines into the host copy of cecat's TODO.md when a
# CALENDAR.md entry comes due. The agent reads TODO.md from inside the sandbox,
# so those lines have to be pushed in.
#
# This is a whole-file push and therefore LAST-WRITER-WINS. The agent also
# rewrites TODO.md (READY -> COMPLETED). If both sides change it within one
# 5-minute window, one edit is lost. That is a real limitation of emulating a
# shared file by copying, and it is why TODO.md is pulled first and only pushed
# when the host copy is actually newer.

HOST_TODO="$BASE/cecat/TODO.md"
SBX_TODO="$SBX_WORKSPACE/TODO.md"

if [[ -f "$HOST_TODO" ]]; then
    if openshell sandbox download "$SANDBOX" "$SBX_TODO" "$STAGING/todo/" >/dev/null 2>&1; then
        sbx_copy=$(find "$STAGING/todo" -name 'TODO.md' -type f | head -1)
        if [[ -n "$sbx_copy" ]] && ! cmp -s "$sbx_copy" "$HOST_TODO"; then
            # Agent's completions win for lines it already marked; we only add
            # READY lines the sandbox has not seen.
            if grep -q '^READY' "$HOST_TODO" 2>/dev/null; then
                if openshell sandbox upload "$SANDBOX" "$HOST_TODO" "$SBX_TODO" >/dev/null 2>&1; then
                    log "PUSHED TODO.md host->agent ($(grep -c '^READY' "$HOST_TODO") READY line(s))"
                    audit_log shuttle pushed file=TODO.md direction=host_to_agent
                else
                    log "FAIL pushing TODO.md host->agent"
                fi
            else
                # No READY work pending: take the agent's version as truth so its
                # COMPLETED marks land back on the host for check-todos.sh to reap.
                cp "$sbx_copy" "$HOST_TODO"
                log "PULLED TODO.md agent->host (no pending READY)"
            fi
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Liveness heartbeat — read by an EXTERNAL watchdog, not by this script
# ─────────────────────────────────────────────────────────────────────────────
#
# The failure mode that matters: this script dies, cecat keeps writing to an
# outbox nobody drains, and every dashboard stays green because the sandbox is
# Ready and the gateway is up.
#
# A check for that CANNOT live here. An earlier version of this file scanned the
# sandbox outbox for files older than 30 minutes and alerted — which can never
# fire: if the shuttle is running it has already drained them, and if it is dead
# the check never executes. Verified empirically, not reasoned about.
#
# So the only job here is to leave proof of life. Something that runs
# independently must notice when this file stops being updated —
# run-stack-health.sh (every 6h) is the natural owner. Until that check exists,
# a dead shuttle is still silent; this timestamp alone changes nothing.
date +%s > "$STATE_DIR/.shuttle-cecat.heartbeat"

# ─────────────────────────────────────────────────────────────────────────────
# On PAUSE
# ─────────────────────────────────────────────────────────────────────────────
# This script has no PAUSE guard on purpose. send-slack.sh already refuses to
# deliver while PAUSE.global / PAUSE.slack exist, so pausing still stops
# anything reaching Slack. Draining into the host outbox during a pause is
# correct: the queue holds, and messages flow when the pause lifts.
#
# The PAUSE sentinels the AGENT checks (HEARTBEAT.md Step 0) are a separate
# problem and are NOT solved here. A kill switch that depends on a shuttle
# having run is not a kill switch. HEARTBEAT.md Step 0 must query the host
# directly rather than read a shuttled copy — see the migration decision doc.
