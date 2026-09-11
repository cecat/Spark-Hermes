#!/usr/bin/env bash
# install-reset-guard-cron.sh — add the context-overflow guard to the crontab.
#
#   bash ops/install-reset-guard-cron.sh --check    # show the diff, change nothing
#   bash ops/install-reset-guard-cron.sh --commit   # install
#   bash ops/install-reset-guard-cron.sh --revert   # restore the pre-install backup
#
# ── WHY ─────────────────────────────────────────────────────────────────────
#
# The legacy guard `shared/scripts/cron/reset-sessions.sh` ran 4x/day and kept
# agent sessions from growing past the model's context window. It was swept into
# `.attic/2026-09-03-t2-retirement/` during the T2 migration with **no
# decision-log entry**, even though THRESHOLD-2-PLAN.md:210 explicitly classifies
# it as "Stay host-side."
#
# Its absence caused cecat to die silently for ~14 hours on 2026-09-07: every
# heartbeat rejected in precheck, zero tokens emitted, auto-compaction unable to
# recover because compaction is itself a model call carrying the same oversized
# prompt. She kept answering Slack, so nothing looked wrong.
#
# `ops/reset-sessions-openshell.sh` is the replacement, retargeted at the
# OpenShell sandboxes. This script wires it into cron.
#
# Cadence 02:17/08:17/14:17/20:17 matches the legacy 4x/day. The :17 offset
# keeps it off the busy :00 boundary where check-todos, send-slack and the
# health checks all fire. TZ=America/Chicago is already set at the top of the
# crontab and is documented as load-bearing for reset timing.
#
# Idempotent: refuses to add a second copy if one is already present.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
    *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

GUARD="$HOME/code/Spark-Hermes/ops/reset-sessions-openshell.sh"
LOG="$HOME/code/spark-ai-agents/shared/logs/sessions-reset-cron.log"
BACKUP_DIR="$HOME/code/Spark-Hermes/runlog"
MARKER="reset-sessions-openshell.sh"

if [ ! -x "$GUARD" ] && [ ! -f "$GUARD" ]; then
    echo "FAIL: guard script not found at $GUARD" >&2
    exit 1
fi

CUR="$(crontab -l 2>/dev/null)" || { echo "FAIL: cannot read crontab" >&2; exit 1; }

if [ "$ACT" = revert ]; then
    LATEST="$(ls -t "$BACKUP_DIR"/crontab.bak-pre-reset-guard-* 2>/dev/null | head -1)"
    if [ -z "$LATEST" ]; then
        echo "FAIL: no pre-install backup found in $BACKUP_DIR" >&2
        exit 1
    fi
    echo "Restoring crontab from: $LATEST"
    crontab "$LATEST" && echo "  DONE — reverted." || { echo "FAIL: crontab restore failed" >&2; exit 1; }
    exit 0
fi

if printf '%s\n' "$CUR" | grep -qF "$MARKER"; then
    echo "Already installed — crontab already references $MARKER."
    printf '%s\n' "$CUR" | grep -nF "$MARKER"
    exit 0
fi

# Invoke via `bash <script>`, NOT `<script>` directly. On 2026-09-08 the guard
# was installed while the file lacked its execute bit; cron dutifully fired at
# 08:17 and logged only `Permission denied`. The guard was dead for hours and
# nothing said so — the same silent-failure shape it exists to prevent.
# `bash <path>` cannot fail that way.
NEWLINE="17 2,8,14,20 * * * bash $GUARD --commit >> $LOG 2>&1"

echo "════════════════════════════════════════════════════════════════"
echo "  Would append to crontab (currently $(printf '%s\n' "$CUR" | wc -l) lines):"
echo "════════════════════════════════════════════════════════════════"
echo
echo "# Context-overflow guard for the OpenShell OpenClaw agents."
echo "# Replaces the legacy reset-sessions.sh lost in the T2 migration; its"
echo "# absence caused cecat's silent 14-hour outage on 2026-09-07."
echo "# Calibration + reasoning: runbook/decision-log.md 2026-09-08-A."
echo "$NEWLINE"
echo

if [ "$ACT" = check ]; then
    echo "  --check only. Nothing changed."
    echo "  To install:  bash ops/install-reset-guard-cron.sh --commit"
    exit 0
fi

mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/crontab.bak-pre-reset-guard-$(date -u +%Y%m%dT%H%M%SZ)"
printf '%s\n' "$CUR" > "$BACKUP" || { echo "FAIL: could not write backup" >&2; exit 1; }
echo "  BACKUP -> $BACKUP"

{
    printf '%s\n' "$CUR"
    echo
    echo "# Context-overflow guard for the OpenShell OpenClaw agents."
    echo "# Replaces the legacy reset-sessions.sh lost in the T2 migration; its"
    echo "# absence caused cecat's silent 14-hour outage on 2026-09-07."
    echo "# Calibration + reasoning: runbook/decision-log.md 2026-09-08-A."
    echo "$NEWLINE"
} | crontab - || { echo "FAIL: crontab install failed. Restore: crontab $BACKUP" >&2; exit 1; }

echo "  INSTALLED"
echo
echo "  VERIFY:"
echo "    crontab -l | grep reset-sessions-openshell"
echo "  REVERT:"
echo "    bash ops/install-reset-guard-cron.sh --revert"
