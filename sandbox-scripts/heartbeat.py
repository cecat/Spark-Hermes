#!/usr/bin/env python3
"""
Gandalf heartbeat (sandbox-side, no-LLM).

Runs every 15 minutes inside the Gandalf OpenShell sandbox under
`hermes cron --no-agent --script`. Performs a set of cheap liveness
checks and:

  - On success: prints NOTHING. Empty stdout means Hermes delivers no
    Slack message (its no-agent contract). The point is to not nag
    Charlie every 15 min with "everything's fine" — just stamp the
    timestamp file and exit.
  - On failure: prints one Slack-ready line per failing check. Charlie
    sees a DM only when something needs his attention.

ALSO writes /sandbox/.hermes/state/heartbeat-last.json with a timestamp
every successful run. This is the positive-liveness signal: a separate
dead-mans-switch check (TODO, not built yet) can compare wall-clock
time against the file's mtime and alert if heartbeats have stopped
firing entirely (gateway died, container died, etc).

Mirrors OpenClaw's HEARTBEAT.md pattern: code for procedure, LLM for
judgment. No model decisions here — just shell-out checks with
deterministic pass/fail.

Checks performed (each is one logical line of output on failure):
  1. Hermes gateway process is alive (pgrep)
  2. /sandbox/.hermes/outbox/{pending,posted,approved,sent,failed} exist + writable
  3. google_token.json exists and `expiry` is a parseable date (string or None)
  4. Disk free in /sandbox > 1 GiB
  5. Last outbox-send cron tick was within 15 min (i.e. it's still ticking)

Output format (each failure):
  ⚠️ [heartbeat] <check-name>: <one-line description of what's wrong>
"""
from __future__ import annotations
import datetime
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/sandbox/.hermes"))
OUTBOX = HERMES_HOME / "outbox"
STATE_DIR = HERMES_HOME / "state"
STATE_FILE = STATE_DIR / "heartbeat-last.json"
TOKEN_PATH = HERMES_HOME / "google_token.json"

OUTBOX_DIRS = ("pending", "posted", "approved", "sent", "failed")
MIN_FREE_GIB = 1.0


def fail(name: str, msg: str) -> str:
    return f"⚠️ [heartbeat] {name}: {msg}"


def check_gateway_alive() -> str | None:
    try:
        p = subprocess.run(["pgrep", "-f", "hermes gateway"],
                           capture_output=True, text=True, timeout=5, check=False)
        if p.returncode != 0 or not p.stdout.strip():
            return fail("gateway", "no 'hermes gateway' process found (pgrep returned nothing)")
    except Exception as e:
        return fail("gateway", f"pgrep failed: {e!r}")
    return None


def check_outbox_dirs() -> str | None:
    problems: list[str] = []
    for d in OUTBOX_DIRS:
        p = OUTBOX / d
        if not p.exists():
            problems.append(f"{d} missing")
        elif not os.access(p, os.W_OK):
            problems.append(f"{d} not writable")
    if problems:
        return fail("outbox-dirs", ", ".join(problems))
    return None


def check_token_shape() -> str | None:
    if not TOKEN_PATH.exists():
        return fail("token", f"{TOKEN_PATH} does not exist (run post-rebuild.sh)")
    try:
        t = json.loads(TOKEN_PATH.read_text())
    except Exception as e:
        return fail("token", f"google_token.json is unreadable JSON: {e!r}")
    e = t.get("expiry")
    if e is None:
        return None  # fine; google-auth will refresh on next call
    if isinstance(e, int):
        # outbox-send.py normalizes this on its own ticks but flag it so we know
        return fail("token", f"expiry is an int ({e}); next cold reader will crash. Run outbox-send.py once to normalize.")
    if isinstance(e, str):
        try:
            datetime.datetime.fromisoformat(e.rstrip("Z"))
            return None
        except ValueError:
            return fail("token", f"expiry string is not parseable: {e!r}")
    return fail("token", f"expiry has unexpected type: {type(e).__name__}")


def check_disk_free() -> str | None:
    try:
        stat = shutil.disk_usage("/sandbox")
    except Exception as e:
        return fail("disk", f"disk_usage(/sandbox) failed: {e!r}")
    free_gib = stat.free / (1024 ** 3)
    if free_gib < MIN_FREE_GIB:
        return fail("disk", f"only {free_gib:.2f} GiB free on /sandbox (threshold {MIN_FREE_GIB} GiB)")
    return None


def check_outbox_send_recent() -> str | None:
    """The outbox-send cron job stamps `Last run` in `hermes cron list`. If it
    hasn't run in the last 20 minutes (we run every 5, so 20 = 4 missed
    ticks), something is wrong with the scheduler or that script."""
    try:
        p = subprocess.run(["/usr/local/bin/hermes", "cron", "list"],
                           capture_output=True, text=True, timeout=10, check=False)
    except Exception as e:
        return fail("scheduler", f"hermes cron list failed: {e!r}")
    if p.returncode != 0:
        return fail("scheduler", f"hermes cron list returned rc={p.returncode}")
    # Parse "Last run: ISO-8601  ok|error" lines under "Name: outbox-send"
    lines = p.stdout.splitlines()
    in_job = False
    last_run = None
    for line in lines:
        s = line.strip()
        if s.startswith("Name:"):
            in_job = ("outbox-send" in s)
            continue
        if in_job and s.startswith("Last run:"):
            # e.g. "Last run:  2026-06-19T11:49:15.508406+00:00  ok"
            try:
                ts_str = s.split(None, 2)[2].split()[0]
                last_run = datetime.datetime.fromisoformat(ts_str)
            except Exception:
                pass
            break
    if last_run is None:
        return fail("scheduler", "outbox-send job has no Last run yet (newly created, or never ticked)")
    now = datetime.datetime.now(datetime.timezone.utc)
    age = (now - last_run).total_seconds() / 60.0
    if age > 20.0:
        return fail("scheduler", f"outbox-send last ran {age:.1f} min ago (threshold 20 min) — scheduler may be wedged")
    return None


def stamp_state(ok: bool, failures: list[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ok": ok,
        "failures": failures,
    }
    STATE_FILE.write_text(json.dumps(payload, indent=2))


def main() -> int:
    checks = [
        check_gateway_alive,
        check_outbox_dirs,
        check_token_shape,
        check_disk_free,
        check_outbox_send_recent,
    ]
    failures: list[str] = []
    for c in checks:
        try:
            result = c()
            if result:
                failures.append(result)
        except Exception as exc:
            failures.append(fail(c.__name__, f"check raised: {exc!r}"))

    stamp_state(ok=not failures, failures=failures)

    if failures:
        print("\n".join(failures))
    # else: silent (empty stdout → no Slack DM by Hermes contract)
    return 0


if __name__ == "__main__":
    sys.exit(main())
