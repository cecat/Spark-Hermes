#!/usr/bin/env python3
"""
Dead-man's switch for agent heartbeats — host-side, no-LLM.

    python3 ops/check-agent-liveness.py                 # all agents, silent if fresh
    python3 ops/check-agent-liveness.py luoji           # one agent
    python3 ops/check-agent-liveness.py --verbose       # print every verdict
    python3 ops/check-agent-liveness.py --alert telegram

Answers the one question no other check on this box asks: "has this agent
stopped doing anything?" Every existing probe asks "is this component
responding right now" — an agent whose heartbeat died silently looks exactly
like a healthy idle agent, and `ops/status.sh` stays green through a total
in-sandbox outage.

WHY IT RUNS ON THE HOST BUT READS INSIDE THE SANDBOX
A dead-man's switch that runs inside the thing it monitors dies with it: if the
sandbox is down, an in-sandbox checker is down too and nobody is left to notice
the silence. So the SCHEDULING is host-side (systemd timer). But a purely
host-side check that never looks inside the sandbox is exactly how the 11-day
Telegram outage went unnoticed, so the EVIDENCE is read from inside — via the
agent's own bind-mounted workspace where one exists, else `docker exec`.
Host clock, in-sandbox evidence.

WHERE EACH AGENT'S EVIDENCE ACTUALLY COMES FROM (verified 2026-09-01)
Two of three agents were previously pointed at paths that do not exist. The
real picture:

  gandalf  docker exec into openshell-gandalf-*, reading
           /sandbox/.hermes/state/heartbeat-last.json → field `checked_at`.
           Written by sandbox-scripts/heartbeat.py:156-160 every 15 min by the
           gateway's own cron. Gandalf's sandbox has NO workspace bind mount
           (only the openshell-sandbox binary), so docker exec is the only way in.

  cecat    HOST READ of
           ~/code/Spark-OpenClaw/cecat/memory/heartbeat-state.json
           → field `lastTriageTimestamp`.
           Her OpenClaw sandbox bind-mounts /workspace from that host directory
           (docker inspect openclaw-sbx-agent-cecat-*), so a host read IS an
           in-sandbox read — no docker exec needed, and no staleness risk from
           reading a copy. The field is written by RUNBOOK_GMAIL_TRIAGE.md Step
           5, hourly, and ONLY on a pass that completed successfully. That
           success gate is what makes it a health signal rather than an
           activity signal: a triage pass that errors out deliberately leaves
           the timestamp alone, so an error loop goes stale and reads DEAD.
           There is no `heartbeat-last.json` for cecat and no `checked_at` field
           anywhere in her state — the earlier version of this script invented both.

  luoji    NO SOURCE. He has a memory/heartbeat-state.json, but it is 91 bytes
           holding a single epoch (`lastChecks.email`) last written 2025-03-17 —
           over a year stale, and nothing in his workspace writes it any more.
           His runbooks have no equivalent of cecat's Step 5. He is therefore
           UNMONITORABLE today and this script says so, rather than pointing at
           a file that cannot answer the question.

  Rejected as a source: ~/code/Spark-OpenClaw/shared/logs/heartbeat.log (dead
  since 2026-05-28), and file mtime for any agent — a file rewritten every cycle
  with identical failing content has a fresh mtime and a dead agent.

WHAT W10 MUST BUILD TO CLOSE THE GAP (stamp contract)
luoji has no liveness source at all, and cecat's is a side effect of one
particular runbook rather than a dedicated beat. Both should get the same
three-line deterministic stamp gandalf already has. The contract:

    path   luoji: <workspace>/memory/heartbeat-last.json
           cecat: <workspace>/memory/heartbeat-last.json
           (<workspace> is /workspace inside the sandbox, which is
            ~/code/Spark-OpenClaw/<agent>/ on the host — bind-mounted rw)
    field  checked_at
    format "%Y-%m-%dT%H:%M:%SZ", UTC, zero-padded, literal trailing Z
    body   {"checked_at": "...", "ok": <bool>, "failures": [<str>, ...]}
    when   last step of every heartbeat, unconditionally — including failing
           runs. `ok` carries pass/fail; `checked_at` only ever means "the beat
           executed". Do NOT gate the write on success; that conflates "the
           agent is gone" with "the agent's work failed".
    model  sandbox-scripts/heartbeat.py:156-160 in this repo.

Once those exist, move cecat and luoji to a {"kind": "host", ...} source with
fields ["checked_at"] and delete their no_source blocks below.

WHY NOT LINE-COUNT GROWTH
`cron/seed-sessions.sh` currently infers liveness from session-file line-count
growth. A heartbeat that fails identically every cycle — model 401, tool
timeout, "No session found" — appends lines just as fast as a healthy one, so
an error loop reads as perfectly healthy. Growth is an ACTIVITY signal, never a
HEALTH signal. This script only ever trusts a timestamp the agent itself wrote
on a run it completed.

VERDICTS
  FRESH    stamp is within threshold of active time. Silent.
  ASLEEP   now is outside the agent's activeHours. Silent — an agent that is
           intentionally off overnight is not dead.
  DEAD     no stamp within threshold, measured in ACTIVE time. Alerts.
  UNKNOWN  could not determine: file missing, sandbox down, unreadable,
           unparseable, no timestamp field. Alerts. Absence of evidence is
           never PASS.

Staleness is measured in ACTIVE-hours elapsed, not wall-clock, so an agent that
sleeps 22:00-08:00 is not declared dead at 08:05 for a stamp written at 21:55.

Exit: 0 all FRESH/ASLEEP · 1 at least one DEAD · 2 at least one UNKNOWN (no DEAD)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

REPO = Path(__file__).resolve().parent.parent
STATE_FILE = Path.home() / ".hermes" / "state" / "agent-liveness.json"
HERMES_CONFIG = Path(os.environ.get("HERMES_CONFIG", Path.home() / ".hermes" / "config.yaml"))
HERMES_ENV = Path.home() / ".hermes" / ".env"

# Re-alert cadence while an agent stays bad, so a timer does not nag every tick.
RENOTIFY_HOURS = 6.0

# Per-agent config. Add a block here when a 4th agent arrives.
#
# threshold_min is sized off the agent's real beat interval: enough slack for
# two missed beats before we call it, so a single hiccup does not page anyone.
#
# A source is one of:
#   {"kind": "host",      "path": <absolute host path>}
#   {"kind": "docker",    "match": <container-name regex>, "path": <in-container path>}
#   {"kind": "no_source", "reason": <why this agent cannot be observed>}
# Sources are tried IN ORDER; the first readable one wins. A "no_source" entry
# is never readable — it exists to make the resulting UNKNOWN say WHY, instead
# of "file not found" for a file nobody was ever going to write.
AGENTS: dict[str, dict] = {
    "gandalf": {
        "interval_min": 15,
        "threshold_min": 45,
        "active_hours": None,  # 24/7 — ~/.hermes/config.yaml cron "every 15m"
        "timezone": "America/Chicago",
        "fields": ["checked_at"],
        "sources": [
            # No workspace bind mount on this sandbox; docker exec is the only way in.
            {"kind": "docker", "match": r"^openshell-gandalf-",
             "path": "/sandbox/.hermes/state/heartbeat-last.json"},
        ],
    },
    "cecat": {
        # Her beat is 15 min, but the field we can observe (lastTriageTimestamp)
        # is only advanced by the HOURLY triage runbook, so the threshold is
        # sized off that hour — not off the beat. Until W10 lands the real
        # checked_at stamp, this switch detects "triage has stopped", which is a
        # strict subset of "cecat has stopped": she could be alive with triage
        # broken, but she cannot be dead with triage running.
        "interval_min": 60,
        "threshold_min": 150,
        "active_hours": None,  # triage is scheduled hourly around the clock
        "timezone": "America/Chicago",
        "fields": ["checked_at", "lastTriageTimestamp"],
        "sources": [
            # Preferred once W10 lands the contract in the module docstring.
            {"kind": "host",
             "path": Path.home() / "code/Spark-OpenClaw/cecat/memory/heartbeat-last.json"},
            # Live today. This host path IS the sandbox's /workspace/memory —
            # openclaw-sbx-agent-cecat-* bind-mounts it rw, so this is
            # in-sandbox evidence read with a host clock, not a stale copy.
            {"kind": "host",
             "path": Path.home() / "code/Spark-OpenClaw/cecat/memory/heartbeat-state.json"},
        ],
    },
    "luoji": {
        "interval_min": 15,
        "threshold_min": 45,
        # From the last openclaw.json that still carried his heartbeat block
        # (_snapshots/openclaw/20260411-123719). Held here deliberately:
        # suppressing overnight alerts is the safer error than paging Charlie at
        # 03:00 for an agent that is supposed to be asleep.
        "active_hours": ("08:00", "22:00"),
        "timezone": "America/Chicago",
        "fields": ["checked_at"],
        "sources": [
            # Where W10's stamp will land. Absent today.
            {"kind": "host",
             "path": Path.home() / "code/Spark-OpenClaw/luoji/memory/heartbeat-last.json"},
            {"kind": "no_source",
             "reason": "no heartbeat stamp is being written for luoji. His "
                       "memory/heartbeat-state.json holds one epoch "
                       "(lastChecks.email) last written 2025-03-17 and nothing "
                       "updates it; his runbooks have no equivalent of cecat's "
                       "triage Step 5. UNMONITORABLE until W10 writes "
                       "memory/heartbeat-last.json {\"checked_at\": ...} — see "
                       "the stamp contract at the top of this file"},
        ],
    },
}


# ── reading the stamp ────────────────────────────────────────────────────────

def read_host(src: dict) -> tuple[str | None, str]:
    p = Path(src["path"])
    if not p.exists():
        return None, f"{p} does not exist"
    try:
        return p.read_text(), "ok"
    except Exception as e:
        return None, f"{p} unreadable: {e!r}"


def read_no_source(src: dict) -> tuple[str | None, str]:
    """Never readable. Declares an agent we cannot observe, so the UNKNOWN it
    produces names the missing mechanism instead of a missing file."""
    return None, src["reason"]


def read_docker(src: dict) -> tuple[str | None, str]:
    try:
        ps = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                            capture_output=True, text=True, timeout=15, check=False)
    except Exception as e:
        return None, f"docker ps failed: {e!r}"
    if ps.returncode != 0:
        return None, f"docker ps rc={ps.returncode}"
    con = next((n for n in ps.stdout.split() if re.search(src["match"], n)), None)
    if not con:
        return None, f"no running container matching {src['match']} (sandbox down?)"
    try:
        r = subprocess.run(["docker", "exec", con, "cat", src["path"]],
                           capture_output=True, text=True, timeout=20, check=False)
    except Exception as e:
        return None, f"docker exec {con} failed: {e!r}"
    if r.returncode != 0:
        err = r.stderr.strip().splitlines()[-1] if r.stderr.strip() else f"rc={r.returncode}"
        return None, f"cannot read {src['path']} in {con}: {err}"
    return r.stdout, "ok"


def parse_stamp(raw: str, fields: list[str]) -> tuple[dt.datetime | None, str, str | None]:
    """Returns (timestamp, why, field_used). field_used is surfaced in the
    verdict because WHICH field answered changes what the verdict means —
    `checked_at` is a real beat, `lastTriageTimestamp` is a proxy."""
    try:
        data = json.loads(raw)
    except Exception as e:
        return None, f"stamp is not parseable JSON: {e!r}", None
    if not isinstance(data, dict):
        return None, "stamp JSON is not an object", None
    for f in fields:
        v = data.get(f)
        if v is None:
            continue
        if isinstance(v, (int, float)):
            return dt.datetime.fromtimestamp(v, dt.timezone.utc), "ok", f
        if isinstance(v, str):
            try:
                ts = dt.datetime.fromisoformat(v.replace("Z", "+00:00"))
            except ValueError:
                return None, f"field {f!r} is not a parseable timestamp: {v!r}", None
            return (ts if ts.tzinfo else ts.replace(tzinfo=dt.timezone.utc)), "ok", f
        return None, f"field {f!r} has unexpected type {type(v).__name__}", None
    return None, (f"no timestamp field (looked for {', '.join(fields)}) — "
                  "heartbeat is not stamping"), None


# ── activeHours arithmetic ───────────────────────────────────────────────────

def _hm(s: str) -> dt.time:
    h, m = s.split(":")
    return dt.time(int(h), int(m))


def is_active_now(now: dt.datetime, window) -> bool:
    if not window:
        return True
    start, end = _hm(window[0]), _hm(window[1])
    t = now.timetz().replace(tzinfo=None)
    return start <= t < end if start <= end else (t >= start or t < end)


def active_seconds(start: dt.datetime, end: dt.datetime, window, tz: ZoneInfo) -> float:
    """Seconds of ACTIVE time between two instants. Wall-clock when there is no
    window. This is what stops an overnight sleep from reading as death."""
    if end <= start:
        return 0.0
    if not window:
        return (end - start).total_seconds()

    start, end = start.astimezone(tz), end.astimezone(tz)
    ws, we = _hm(window[0]), _hm(window[1])
    total = 0.0
    day = start.date()
    # Bounded so a stamp from months ago cannot spin: the verdict is DEAD long
    # before the cap matters.
    for _ in range(400):
        if day > end.date():
            break
        midnight = dt.datetime.combine(day, dt.time(0, 0), tzinfo=tz)
        spans = ([(dt.datetime.combine(day, ws, tzinfo=tz),
                   dt.datetime.combine(day, we, tzinfo=tz))]
                 if ws <= we else
                 [(midnight, dt.datetime.combine(day, we, tzinfo=tz)),
                  (dt.datetime.combine(day, ws, tzinfo=tz), midnight + dt.timedelta(days=1))])
        for a, b in spans:
            lo, hi = max(a, start), min(b, end)
            if hi > lo:
                total += (hi - lo).total_seconds()
        day += dt.timedelta(days=1)
    return total


# ── verdict ──────────────────────────────────────────────────────────────────

def check(name: str, cfg: dict, now_utc: dt.datetime) -> dict:
    tz = ZoneInfo(cfg["timezone"])
    window = cfg["active_hours"]
    now_local = now_utc.astimezone(tz)

    readers = {"host": read_host, "docker": read_docker, "no_source": read_no_source}

    raw, why, used = None, "no sources configured", None
    reasons = []
    for src in cfg["sources"]:
        raw, why = readers[src["kind"]](src)
        if raw is not None:
            used = src
            break
        reasons.append(why)

    if raw is None:
        return {"agent": name, "verdict": "UNKNOWN",
                "detail": "; ".join(reasons) or why, "stamp": None}

    stamp, why = parse_stamp(raw, cfg["fields"])
    if stamp is None:
        loc = used["path"] if used else "?"
        return {"agent": name, "verdict": "UNKNOWN", "detail": f"{loc}: {why}", "stamp": None}

    age_min = active_seconds(stamp, now_utc, window, tz) / 60.0
    wall_min = (now_utc - stamp).total_seconds() / 60.0
    stamp_s = stamp.astimezone(tz).strftime("%Y-%m-%d %H:%M %Z")

    if age_min > cfg["threshold_min"]:
        # An agent outside its window is not dead, it is off shift. Report the
        # staleness but never alert on it — alerting here is how you train
        # someone to ignore the alert.
        if not is_active_now(now_local, window):
            return {"agent": name, "verdict": "ASLEEP", "stamp": stamp_s,
                    "detail": f"outside activeHours {window[0]}-{window[1]} {cfg['timezone']}; "
                              f"last stamp {stamp_s} ({wall_min/60:.1f}h wall)"}
        return {"agent": name, "verdict": "DEAD", "stamp": stamp_s,
                "detail": f"last stamp {stamp_s} — {age_min:.0f} min of active time ago "
                          f"(threshold {cfg['threshold_min']} min, interval {cfg['interval_min']} min)"}

    return {"agent": name, "verdict": "FRESH", "stamp": stamp_s,
            "detail": f"last stamp {stamp_s} ({age_min:.0f} min active ago)"}


# ── alerting ─────────────────────────────────────────────────────────────────

def cfg_value(key: str) -> str | None:
    """Read a dotted key from ~/.hermes/config.yaml without a yaml dependency."""
    if not HERMES_CONFIG.exists():
        return None
    top, leaf = key.split(".", 1)
    in_top = False
    for line in HERMES_CONFIG.read_text().splitlines():
        if re.match(rf"^{re.escape(top)}\s*:", line):
            in_top = True
            continue
        if in_top:
            if line and not line[0].isspace():
                break
            m = re.match(rf"^\s+{re.escape(leaf)}\s*:\s*(.+)$", line)
            if m:
                return m.group(1).strip().strip('"').strip("'")
    return None


def env_value(key: str) -> str | None:
    if not HERMES_ENV.exists():
        return None
    for line in HERMES_ENV.read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def send_telegram(text: str) -> str:
    token, chat = env_value("TELEGRAM_BOT_TOKEN"), cfg_value("telegram.group_chat")
    if not token:
        return "telegram: TELEGRAM_BOT_TOKEN not set in ~/.hermes/.env"
    if not chat:
        return "telegram: telegram.group_chat not set in ~/.hermes/config.yaml"
    # urllib, not curl: the token would otherwise sit in argv for anyone running
    # `ps`. (The sandbox's urllib/L7-proxy ban does not apply — this is the host.)
    body = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=body)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return "telegram: sent" if r.status == 200 else f"telegram: HTTP {r.status}"
    except Exception as e:
        return f"telegram: send failed: {e!r}"


def send_slack(text: str) -> str:
    """Drop a pending item in the existing outbox that send-slack.sh drains
    every 5 min. Reuses that path rather than adding a second Slack sender."""
    outbox = Path.home() / "code/Spark-OpenClaw/shared/slack/outbox"
    channel = os.environ.get("LIVENESS_SLACK_CHANNEL") or cfg_value("slack.home_channel_id")
    if not channel:
        return "slack: no channel (set LIVENESS_SLACK_CHANNEL or slack.home_channel_id)"
    if not outbox.is_dir():
        return f"slack: outbox {outbox} does not exist"
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    payload = {"channel": channel, "text": text, "requested_by": "check-agent-liveness",
               "requested_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "status": "pending"}
    dest = outbox / f"{stamp}-agent-liveness.json"
    dest.write_text(json.dumps(payload, indent=2))
    return f"slack: queued {dest.name}"


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True))


def should_alert(prev: dict, verdict: str, now_utc: dt.datetime) -> bool:
    """Alert on entering a bad state, on recovery, and every RENOTIFY_HOURS
    while it persists. Keeps the script safe to run on a tight timer."""
    bad = verdict in ("DEAD", "UNKNOWN")
    was = prev.get("verdict")
    if not bad:
        return was in ("DEAD", "UNKNOWN")
    if was != verdict:
        return True
    try:
        last = dt.datetime.fromisoformat(prev["alerted_at"])
    except Exception:
        return True
    return (now_utc - last).total_seconds() / 3600.0 >= RENOTIFY_HOURS


ICON = {"DEAD": "🔴", "UNKNOWN": "🟠", "FRESH": "🟢", "ASLEEP": "🌙"}


def main() -> int:
    ap = argparse.ArgumentParser(description="Dead-man's switch for agent heartbeats.")
    ap.add_argument("agents", nargs="*", help="agents to check (default: all)")
    ap.add_argument("--alert", choices=["none", "telegram", "slack"], default="none",
                    help="where to send alerts. Default 'none' = print only, sends nothing.")
    ap.add_argument("--verbose", action="store_true", help="print FRESH/ASLEEP too")
    args = ap.parse_args()

    names = args.agents or list(AGENTS)
    unknown_names = [n for n in names if n not in AGENTS]
    if unknown_names:
        print(f"unknown agent(s): {', '.join(unknown_names)}", file=sys.stderr)
        return 2

    now = dt.datetime.now(dt.timezone.utc)
    state = load_state()
    results = []

    for n in names:
        try:
            r = check(n, AGENTS[n], now)
        except Exception as e:
            r = {"agent": n, "verdict": "UNKNOWN", "stamp": None,
                 "detail": f"check raised: {e!r}"}
        results.append(r)

    bad = [r for r in results if r["verdict"] in ("DEAD", "UNKNOWN")]
    to_alert, recovered = [], []
    for r in results:
        prev = state.get(r["agent"], {})
        if should_alert(prev, r["verdict"], now):
            (to_alert if r["verdict"] in ("DEAD", "UNKNOWN") else recovered).append(r)
        entry = {"verdict": r["verdict"], "checked_at": now.isoformat(), "detail": r["detail"]}
        if r in to_alert or r in recovered:
            entry["alerted_at"] = now.isoformat()
        elif "alerted_at" in prev:
            entry["alerted_at"] = prev["alerted_at"]
        state[r["agent"]] = entry
    save_state(state)

    for r in results:
        if args.verbose or r["verdict"] in ("DEAD", "UNKNOWN"):
            print(f"{ICON[r['verdict']]} [liveness] {r['agent']}: {r['verdict']} — {r['detail']}")

    if args.alert != "none" and (to_alert or recovered):
        lines = [f"{ICON[r['verdict']]} {r['agent']}: {r['verdict']} — {r['detail']}"
                 for r in to_alert]
        lines += [f"{ICON['FRESH']} {r['agent']}: RECOVERED — {r['detail']}" for r in recovered]
        sender = send_telegram if args.alert == "telegram" else send_slack
        print(sender("[agent-liveness]\n" + "\n".join(lines)))

    if any(r["verdict"] == "DEAD" for r in bad):
        return 1
    return 2 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
