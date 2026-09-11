#!/usr/bin/env bash
# fix-compaction-settings.sh — give auto-compaction enough time to succeed.
#
#   bash ops/fix-compaction-settings.sh            # --check (default): diff only
#   bash ops/fix-compaction-settings.sh --commit   # patch config + restart gateway
#   bash ops/fix-compaction-settings.sh --revert   # restore the pre-change backup
#
# ── THE BUG THIS FIXES — MEASURED, NOT INFERRED ─────────────────────────────
#
# cecat went totally dark twice (2026-09-07T14:51Z ~14h; 2026-09-08T11:51Z),
# every heartbeat rejected in precheck before the model emitted a token.
# Auto-compaction is supposed to prevent exactly this. It fired every time and
# failed every time — **73 of 73 attempts**, always the same way:
#
#   auto-compaction failed for inference/claudesonnet46: Error: Compaction timed out
#   [compaction-safeguard] Compaction summarization failed; cancelling
#                          compaction to preserve history: Request was aborted
#
# **It is a TIMEOUT, not a size rejection.** The distinction is the whole fix.
# Compaction is itself a model call; ours is being killed by a deadline while it
# is still working. From the log, the wall is exact:
#
#   12:06:01.586  context overflow detected; attempting auto-compaction
#   12:08:01.589  auto-compaction failed: Compaction timed out
#                 = 120.003s against timeoutSeconds: 120
#
# Summarizing a ~116K-token history through a local inference endpoint takes
# longer than 120s. And `qualityGuard.maxRetries: 0` makes the first failure
# terminal, so there is no second chance. Between them, compaction could never
# succeed — which is why an external reset was the only thing that cleared it.
#
# **Both agents carry identical settings**, so luoji has the same latent fault
# and simply has not grown large enough to hit it yet.
#
# ── WHAT CHANGES ────────────────────────────────────────────────────────────
#
#   timeoutSeconds        120 -> 600   room to summarize a large history on a
#                                      local endpoint (5x the observed wall)
#   qualityGuard.maxRetries 0 -> 1     upstream stock; one failure is no longer
#                                      terminal
#
# Everything else is left alone. `mode`, `maxHistoryShare` and
# `truncateAfterCompaction` are not implicated by the evidence, and changing
# untested knobs at the same time would make the result unattributable.
#
# ── WE AUTHORED THESE VALUES — CONFIRMED, NOT AN UPSTREAM BUG ───────────────
#
# W-H2 (2026-09-08) established, and the supervisor verified both claims:
#   * NemoClaw does NOT set them — grep for all five compaction keys across the
#     v0.0.108 blueprint tree returns zero matches.
#   * All config backups back to 2026-08-21 already carry 120/0, so it predates
#     the outages and was authored here.
#
# Upstream stock is **timeoutSeconds 180, maxRetries 1** (per docs). We had set
# 120/0 — both strictly more brittle than stock. **600 is deliberately above
# stock 180**: 180 is tuned for hosted providers, and upstream issues #27595 and
# #43834 both document local endpoints needing far more (one user raised it to
# 1800s). Note `agents.defaults.timeoutSeconds` is already 600 — there is no
# reason for the summarization call to get 1/5 the budget of an ordinary turn on
# the same endpoint. Retries take stock 1, not 2: more retries multiply
# worst-case wall time against an already-slow endpoint.
#
# ── THIS IS THE SECOND-ORDER CAUSE. THE FIRST-ORDER CAUSE IS UNFIXED. ───────
#
# The heartbeat runs every 15m into ONE never-reset session — `agents.list` has a
# single agent `main` with `heartbeat: {every: 15m}` and **no isolation key at
# all** (verified). History therefore accrues forever and compaction is the only
# thing between us and the cliff.
#
# Upstream's answer to unbounded recurring-task growth is **session isolation**
# (`isolation.resetBetweenRuns` / `maxHistoryRuns`), i.e. *do not accumulate* —
# not *summarize harder*. Our cron truncation guard is a hand-rolled
# reimplementation of `resetBetweenRuns`.
#
# **This script does not fix that.** It makes compaction able to succeed, which
# is necessary but not sufficient.
#
# **CORRECTION (W-I, 2026-09-08):** an earlier version of this comment called the
# isolation key "unverified." It was not unverified — it was WRONG.
# `isolation.resetBetweenRuns` / `maxHistoryRuns` **do not exist** in this build.
# The real keys are **`isolatedSession`** and **`lightContext`**, and the running
# 2026.7.1 gateway state DB carries a full automation subsystem (`cron_jobs`
# with `trigger_script`, `trigger_once`, `wake_mode`, `payload_light_context`;
# also `cron_run_logs`, `task_runs`, `flow_runs`) that is **migrated and
# completely unused — 0 rows.** See runbook/DESIGN-heartbeat-deterministic.md.
# The real fix is `isolatedSession: true` plus a script-gated automation job, and
# it needs no host cron and nothing from Gandalf's plane.
#
# ── THE GUARD STAYS FOR NOW ─────────────────────────────────────────────────
#
# Keep `ops/reset-sessions-openshell.sh` through at least one full cycle after
# this lands. Upstream #71325 reports that `mode: safeguard` can fail to trigger
# *proactively* because the context engine's windowed view hides true session
# size — so raising the timeout may fix only the emergency path. A 14-hour
# silent outage is worse than a crude truncation. **Once you observe compaction
# completing AND isolation resetting, delete the guard** — leaving it in place
# masks whether the real fix works.
#
# **The proof is a log line, not this script's output:** an overflow followed by
# a compaction that SUCCEEDS, and no reset needed. Until you see that, assume
# nothing.
#
# ── C-0b ────────────────────────────────────────────────────────────────────
#
# --commit overwrites a live config and restarts a gateway. It backs the config
# up first (in-sandbox, timestamped) and --revert restores it.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
    *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

NEW_TIMEOUT="${NEW_TIMEOUT:-600}"
NEW_RETRIES="${NEW_RETRIES:-1}"
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
        echo "        is the sshfs mount up?  ops/mount-agent-filespaces.sh --check"
        RC=1; continue
    fi

    if [ "$ACT" = revert ]; then
        BK="$(ls -t "$MNT/.openclaw/"openclaw.json.pre-compaction-* 2>/dev/null | head -1)"
        if [ -z "$BK" ]; then
            echo "  FAIL: no pre-compaction backup found"; RC=1; continue
        fi
        cp "$BK" "$CFG" && echo "  REVERTED from $(basename "$BK")" || { echo "  FAIL: restore"; RC=1; }
        continue
    fi

    # Read current values and emit the patched document. Never edit JSON with
    # sed — one stray match would corrupt a live gateway config.
    OUT="$(python3 - "$CFG" "$NEW_TIMEOUT" "$NEW_RETRIES" <<'PY'
import json, sys
cfg, newt, newr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = json.load(open(cfg))
except Exception as e:
    print("PARSE_FAIL %s" % e); raise SystemExit(0)
c = (d.get("agents", {}).get("defaults", {}) or {}).get("compaction")
if not isinstance(c, dict):
    print("NO_COMPACTION_BLOCK"); raise SystemExit(0)
qg = c.get("qualityGuard") or {}
curt, curr = c.get("timeoutSeconds"), qg.get("maxRetries")
if curt == newt and curr == newr:
    print("ALREADY %s %s" % (curt, curr)); raise SystemExit(0)
c["timeoutSeconds"] = newt
qg["maxRetries"] = newr
c["qualityGuard"] = qg
print("PATCH %s %s" % (curt, curr))
print(json.dumps(d, indent=2))
PY
)"

    STATUS="$(printf '%s\n' "$OUT" | head -1)"
    case "$STATUS" in
        PARSE_FAIL*|NO_COMPACTION_BLOCK)
            echo "  FAIL: $STATUS"; RC=1; continue ;;
        ALREADY*)
            echo "  already set (timeoutSeconds=$NEW_TIMEOUT maxRetries=$NEW_RETRIES) — no change"
            continue ;;
    esac

    read -r _ CURT CURR <<<"$STATUS"
    echo "  timeoutSeconds:          $CURT -> $NEW_TIMEOUT"
    echo "  qualityGuard.maxRetries: $CURR -> $NEW_RETRIES"

    if [ "$ACT" = check ]; then
        echo "  --check only. Nothing changed."
        continue
    fi

    BK="$MNT/.openclaw/openclaw.json.pre-compaction-$STAMP"
    cp "$CFG" "$BK" || { echo "  FAIL: backup"; RC=1; continue; }
    echo "  BACKUP -> $(basename "$BK")"

    # Validate the new document parses BEFORE it replaces a live config.
    TMP="$CFG.tmp-compaction-$STAMP"
    printf '%s\n' "$OUT" | tail -n +2 > "$TMP"
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null; then
        echo "  FAIL: patched JSON does not parse — original untouched"
        rm -f "$TMP" 2>/dev/null; RC=1; continue
    fi
    cat "$TMP" > "$CFG" && rm -f "$TMP" || { echo "  FAIL: write"; RC=1; continue; }
    echo "  PATCHED"
done

if [ "$ACT" = commit ] && [ "$RC" -eq 0 ]; then
    echo
    echo "  Config patched. The gateway reads compaction settings at start, so"
    echo "  each gateway must be restarted to pick this up. Restarting is a"
    echo "  live control action — run it yourself:"
    echo
    echo "    bash ops/apply-heartbeat.sh --commit    # restarts, or use your usual path"
    echo
    echo "  THEN VERIFY — and do not trust anything but this:"
    echo "    watch for an overflow followed by a compaction that SUCCEEDS in"
    echo "      <agent-mount>/.openclaw/logs/gateway-persistent.log"
    echo "    A 'Compaction timed out' line means the timeout is still too low."
fi

exit "$RC"
