#!/usr/bin/env bash
# apply-heartbeat.sh — restore the agent heartbeat on the OpenShell stack.
#
#   bash ops/apply-heartbeat.sh --check    # report only (default)
#   bash ops/apply-heartbeat.sh --commit   # patch config + restart gateway
#
# ── THE BUG ─────────────────────────────────────────────────────────────────
#
# Found 2026-09-04 because Charlie noticed his Gmail inbox had not been triaged
# all day. Neither cecat nor luoji has ANY heartbeat configuration in its
# OpenShell config: `agents.list[0]` is bare `{"id":"main","default":true}`.
#
# Consequence: the agents never wake on a schedule. Everything else works —
# cecat answers Slack and Telegram, her Gmail API calls succeed, and the HOST
# side of scheduling is fine (check-todos.sh promoted 5 items to READY today at
# 14:00). But nothing drains the queue, so RUNBOOK_GMAIL_TRIAGE sat unexecuted
# at 15:00, 16:00, 17:00, 18:00 and 19:00.
#
# This is the failure mode this project keeps re-learning: **a capability can be
# reachable and still not be working.** Threshold 1 measured the three comms
# channels and Google access — all genuinely green — but never asked whether
# the agents do scheduled work, which is most of what they are FOR.
#
# NOT caused by the 2026-09-03 Telegram change: the pre-change `.bak` also has
# zero heartbeat entries. It never came across when the agents were stood up on
# OpenShell — the same class as the `/scripts/` and `/shared/state/` breakages.
#
# ── THE SHAPE ───────────────────────────────────────────────────────────────
#
# Not invented. Taken from a real working legacy config, still on disk at
# openclaw-gateway:/home/node/agents/_snapshots/openclaw/20260323-224255/
#   "heartbeat": { "every": "15m",
#                  "activeHours": {"start","end","timezone"} }   # optional
#
# luoji had activeHours 08:00-22:00 America/Chicago; cecat ran unrestricted.
# Preserved per-agent below rather than normalised — cecat's inbox triage is
# hourly around the clock by design (see cecat/CALENDAR.md).
set -u

MODE="${1:---check}"
case "$MODE" in
  --check)  DO=0 ;;
  --commit) DO=1 ;;
  *) echo "Usage: $0 [--check|--commit]" >&2; exit 1 ;;
esac

RC=0
for AGENT in cecat luoji; do
    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    if [ -z "$CON" ]; then
        echo "  NO RUNNING SANDBOX — skipped"; RC=1; continue
    fi

    if [ "$DO" = 0 ]; then
        docker exec -u sandbox -i "$CON" python3 - <<'PY'
import json
d = json.load(open("/sandbox/.openclaw/openclaw.json"))
ag = d.get("agents", {})
hb = ag.get("defaults", {}).get("heartbeat")
print(f"  agents.defaults.heartbeat = {json.dumps(hb)}"
      + ("   <-- MISSING; agent never wakes on a schedule" if not hb else ""))
# Automations must be on or scheduled heartbeats never run, silently.
cron = d.get("cron")
print(f"  cron = {json.dumps(cron)}"
      + ("   <-- cron.enabled=false DISABLES heartbeats" if cron and cron.get("enabled") is False else ""))
stray = [a.get("id") for a in ag.get("list", []) if a.get("heartbeat")]
if stray:
    print(f"  WARNING stray heartbeat on agents.list{stray} — wrong key, runtime ignores it")
PY
        continue
    fi

    docker exec -u sandbox -i -e AGENT="$AGENT" "$CON" python3 - <<'PY'
import json, os, shutil

cfg   = "/sandbox/.openclaw/openclaw.json"
agent = os.environ["AGENT"]

# Timestamped backup: the plain .bak is already occupied by the Telegram apply,
# and overwriting a rollback point is how you lose the one you needed.
shutil.copy(cfg, cfg + ".bak-heartbeat")

with open(cfg) as f:
    d = json.load(f)

# CORRECTED 2026-09-05. The first version wrote this to agents.list[].heartbeat,
# copying the shape from the legacy config. The runtime ignored it — 27 minutes,
# zero ticks.
#
# Per https://docs.openclaw.ai/gateway/heartbeat the key is
# `agents.defaults.heartbeat` (global) or `agents.entries.*.heartbeat`
# (per-agent). This build has `agents.list`, not `agents.entries`, and one agent
# per sandbox — so defaults is both correct and unambiguous here.
#
# Only `every` is required. `target` defaults to "owner"; stated explicitly
# because an unresolvable owner route makes heartbeats skip with
# `reason=no-route`, which is silent and looks identical to "not configured".
hb = {"every": "15m", "target": "owner"}
if agent == "luoji":
    # luoji's legacy config restricted him to waking hours; cecat's did not,
    # because her inbox triage is scheduled hourly around the clock.
    hb["activeHours"] = {"start": "08:00", "end": "22:00",
                         "timezone": "America/Chicago"}

d.setdefault("agents", {}).setdefault("defaults", {})["heartbeat"] = hb

# Remove the wrong-key leftovers from the first attempt so the file does not
# carry two conflicting sources of truth.
for a in d.get("agents", {}).get("list", []):
    a.pop("heartbeat", None)

with open(cfg, "w") as f:
    json.dump(d, f, indent=2)

print("  agents.defaults.heartbeat =", json.dumps(hb))
PY

    echo "  --- restarting gateway (SIGTERM; supervisor respawns) ---"
    docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' || true
    sleep 8
    docker exec -u sandbox "$CON" sh -c 'pgrep -af openclaw-gateway | head -2' \
        || { echo "  gateway not back yet"; RC=1; }
    echo
done

if [ "$DO" = 1 ]; then
cat <<'EOM'
════════════════════════════════════════════
  VERIFY — the config is not the proof
════════════════════════════════════════════
  A heartbeat block in the file only means the gateway was ASKED to schedule.
  Wait ~15 minutes, then confirm it actually fires:

    docker logs --tail 5000 -t $(docker ps --format '{{.Names}}' \
      | grep '^openshell-default--cecat-') 2>&1 | grep -i heartbeat | tail -3

  A '[heartbeat] started' line dated AFTER this run is the proof. Before this
  fix, cecat's most recent was 2026-09-03T04:42Z.

  Then confirm the queue drains: cecat/TODO.md had 5 READY items stacked up.
  They should begin flipping to COMPLETED.
EOM
fi
exit $RC
