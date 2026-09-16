#!/usr/bin/env bash
# retire-dead-scripts.sh — retire the dead OpenClaw scripts identified by the
# T2-1 inventory, plus Charlie's four rulings of 2026-09-03.
#
#   bash ops/retire-dead-scripts.sh --dry-run   # default; shows, changes nothing
#   bash ops/retire-dead-scripts.sh --commit    # actually moves files
#
# DELETES NOTHING. Everything is MOVED to a dated attic directory, so any
# mistake is one `mv` away from undone. C-0b: Charlie authorizes destruction;
# this makes the destruction reversible so that authorization is cheap.
#
# CRON IS HANDLED FIRST AND SEPARATELY. Six of these scripts are live in the
# host crontab right now. Retiring the files without removing the cron entries
# would leave six jobs failing every few minutes, which is worse than leaving
# everything alone. The script REFUSES to move a cron-referenced file until the
# crontab is clean.
set -u

MODE="${1:---dry-run}"
BASE="$HOME/code/Spark-OpenClaw"
ATTIC="$BASE/.attic/2026-09-03-t2-retirement"

case "$MODE" in
  --dry-run) DO=0 ;;
  --commit)  DO=1 ;;
  *) echo "Usage: $0 [--dry-run|--commit]" >&2; exit 1 ;;
esac

# ── Files still referenced in the live crontab ──────────────────────────────
CRON_BLOCKED="seed-sessions.sh reset-sessions.sh monitor-sessions.sh
collect-token-usage.sh rotate-sessions-monitor.sh"

echo "════════════════════════════════════════════"
echo "  STEP 1 — crontab entries that must go first"
echo "════════════════════════════════════════════"
STILL_CRONNED=""
for s in $CRON_BLOCKED; do
    if crontab -l 2>/dev/null | grep -q "$s"; then
        echo "  STILL SCHEDULED: $s"
        STILL_CRONNED="$STILL_CRONNED $s"
    fi
done

if [ -n "$STILL_CRONNED" ]; then
    cat <<'EOM'

  These are live in the host crontab. Remove those lines FIRST:

      crontab -e     # delete the lines naming the scripts listed above

  Then re-run this script. It will refuse to move a cron-referenced file,
  because a scheduled job pointing at a moved file fails silently every few
  minutes and nobody notices for weeks.
EOM
fi
echo

# ── The retirement list ─────────────────────────────────────────────────────
# Format: relative-path : one-line reason
RETIRE=$(cat <<'EOM'
shared/scripts/cron/seed-sessions.sh:reads OpenClaw sessions.json - gateway being retired
shared/scripts/cron/reset-sessions.sh:reads OpenClaw sessions.json - gateway being retired
shared/scripts/cron/monitor-sessions.sh:reads OpenClaw sessions.json - gateway being retired
shared/scripts/cron/collect-token-usage.sh:reads OpenClaw sessions.json - gateway being retired
shared/scripts/ops/reset-agent.sh:resets OpenClaw sessions - gateway being retired
shared/scripts/ops/rotate-sessions-monitor.sh:rotates the log of monitor-sessions.sh
shared/scripts/cron/check-iptables.sh:superseded by Spark-Hermes ops/check-parity.sh
shared/scripts/ops/iptables-check.sh:superseded by ops/check-parity.sh
shared/scripts/ops/iptables-drift-test.sh:tests check-iptables.sh, also retiring
shared/scripts/ops/install-iptables-cron.sh:installs check-iptables.sh, also retiring
shared/scripts/ops/phase3-retry.sh:spent one-shot migration script
shared/scripts/ops/phase4c-install-and-test.sh:spent one-shot install script
shared/scripts/agent/scan-logs.sh.bak-pre-rotation-2026-06-07:stale backup
cecat/runbooks/TODO.md:two COMPLETED lines from 2026-06-05, misfiled in runbooks/
cecat/runbooks/RUNBOOK_ONETIME_SYNC.md:Charlie 2026-09-03 - not needed
luoji/runbooks/RUNBOOK_SC26_WORKSHOP_BLAST.md:Charlie 2026-09-03 - not needed
cecat/runbooks/RUNBOOK_STYLE_REVIEW.md:never scheduled; Charlie 2026-09-03 - ignore if unused
cecat/scripts/cecat-harvest-sent-contacts.sh:Charlie 2026-09-03 - superseded by contacts-api.py
cecat/scripts/cecat-harvest-sent-sample.sh:Charlie 2026-09-03 - superseded by contacts-api.py
cecat/scratch/check_contacts.py:untracked one-off triage pass
cecat/scratch/complete_ready.py:untracked one-off triage pass
cecat/scratch/finalize_state.py:untracked one-off triage pass
cecat/scratch/slack_alerts2.py:untracked one-off triage pass
cecat/scratch/slack_jon_freeman.py:untracked one-off triage pass
cecat/scratch/slack_triage_alerts.py:untracked one-off triage pass
cecat/scratch/triage2.py:untracked one-off triage pass
cecat/scratch/triage_batch.py:untracked one-off triage pass
cecat/tmp-slack-triage.py:untracked one-off triage pass
cecat/triage-pass5-slack.py:untracked one-off triage pass
cecat/triage_pass6.py:untracked one-off triage pass
cecat/triage-pass5-batch1.sh:untracked one-off triage pass
cecat/scripts/update-triage-ts.py:untracked one-off triage helper
EOM
)

echo "════════════════════════════════════════════"
echo "  STEP 2 — files to retire"
echo "════════════════════════════════════════════"
N_OK=0; N_SKIP=0; N_MISSING=0
[ "$DO" = 1 ] && mkdir -p "$ATTIC"

while IFS=: read -r rel reason; do
    [ -n "$rel" ] || continue
    src="$BASE/$rel"
    base=$(basename "$rel")

    if [ ! -e "$src" ]; then
        echo "  -- missing (already gone): $rel"
        N_MISSING=$((N_MISSING+1)); continue
    fi
    case " $STILL_CRONNED " in
        *" $base "*)
            echo "  !! SKIP (still in crontab): $rel"
            N_SKIP=$((N_SKIP+1)); continue ;;
    esac

    if [ "$DO" = 1 ]; then
        mkdir -p "$ATTIC/$(dirname "$rel")"
        mv "$src" "$ATTIC/$rel" && echo "  -> moved: $rel"
    else
        echo "  would move: $rel"
        echo "                ($reason)"
    fi
    N_OK=$((N_OK+1))
done <<< "$RETIRE"

echo
echo "════════════════════════════════════════════"
if [ "$DO" = 1 ]; then
    echo "  MOVED $N_OK  |  SKIPPED $N_SKIP  |  ALREADY GONE $N_MISSING"
    echo "  Attic: $ATTIC"
    echo "  Undo any single file:  mv $ATTIC/<path> $BASE/<path>"
else
    echo "  DRY RUN — nothing changed."
    echo "  WOULD MOVE $N_OK  |  BLOCKED BY CRON $N_SKIP  |  ALREADY GONE $N_MISSING"
    echo "  Re-run with --commit once the crontab is clean."
fi
echo "════════════════════════════════════════════"

cat <<'EOM'

TWO LIVE DEPENDENCIES — verified 2026-09-03, neither blocks this:

  shared/scripts/tests/test-infra.sh
      Tests some of the retiring scripts. Its assertions for them will fail
      after retirement. Prune those cases when you next touch it; the file
      itself stays.

  luoji/runbooks/RUNBOOK_HEALTH_REPORT.md
      Mentions the session scripts, but its actual probes are test-all.sh,
      scan-logs.sh and check-outbox-age.sh — all verified clean of any
      gateway reference. This runbook is being KEPT (see THRESHOLD-2-PLAN);
      it loses nothing here.

  Both CHANGELOG.md files also mention these scripts. That is history and is
  correct to leave alone.
EOM
