#!/usr/bin/env python3
"""
Outbox sender (sandbox-side, no-LLM).

Runs inside the Gandalf OpenShell sandbox under `hermes cron --no-agent --script`.
Polls /sandbox/.hermes/outbox/approved/ on every tick; for each draft:

  1. Re-validate recipients against the live thread (Gmail headers + body).
     Operator + agent + every in-thread address = allowlist. Any draft address
     not in the allowlist → reject, move to outbox/failed/.
  2. If valid: call the local google_api.py wrapper to actually send via Gmail.
     On success: move to outbox/sent/ with a .sent.json sidecar (message id).
     On failure: move to outbox/failed/ with a .error.json.
  3. stdout collects one line per draft processed; Hermes' cron delivery
     posts that line back to the operator's Slack DM. Empty stdout = silent
     tick (nothing to send) by Hermes' contract.

Why sandbox-side instead of host-side: the previous outbox-sender.sh on the
host had to docker-exec back into the sandbox per call, which doesn't inherit
the OpenShell L7 proxy env vars (HTTPS_PROXY=http://10.200.0.1:3128 + the
custom CA bundle). Inside the sandbox, the gateway has already set up the
right network namespace, so a normal in-process httplib2 call to
gmail.googleapis.com Just Works. One code path, one set of failure modes.

Idempotent and crash-safe: a draft only moves out of approved/ AFTER the
gmail call returns (success → sent/, failure → failed/).
"""
from __future__ import annotations
import datetime
import json
import os
import subprocess
import sys
import re
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/sandbox/.hermes"))
OUTBOX = HERMES_HOME / "outbox"
APPROVED = OUTBOX / "approved"
SENT = OUTBOX / "sent"
FAILED = OUTBOX / "failed"
TOKEN_PATH = HERMES_HOME / "google_token.json"
GOOGLE_API = "/opt/hermes/skills/productivity/google-workspace/scripts/google_api.py"
PYTHON = "/opt/hermes/.venv/bin/python"

EMAIL_RE = re.compile(r"[\w.+-]+@[\w.-]+\.\w+")

OPERATOR_EMAILS = {"cecatlett@gmail.com", "catlett@anl.gov"}
AGENT_EMAIL = "agentic.cec@gmail.com"


def normalize_token() -> None:
    """google-auth refreshes the token in-process and writes `expiry` as an
    int. A cold reader (this script) then crashes on int.rstrip. Convert
    int → ISO-8601 once per run. Idempotent."""
    try:
        with TOKEN_PATH.open() as f:
            t = json.load(f)
    except FileNotFoundError:
        return
    e = t.get("expiry")
    if isinstance(e, int):
        t["expiry"] = datetime.datetime.fromtimestamp(
            e, datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        with TOKEN_PATH.open("w") as f:
            json.dump(t, f, indent=2)


def call_gmail(args: list[str], timeout: int = 30) -> tuple[int, str, str]:
    # The google-workspace skill needs google-api-python-client, which lives
    # in /sandbox/.hermes/pylibs (installed by ops/post-rebuild.sh — the
    # hermes venv doesn't ship it). PYTHONPATH is set in the gateway's env
    # but NOT inherited by no-agent cron script subprocesses, so we set it
    # explicitly.
    #
    # SSL: googleapiclient uses httplib2, which has its own cert store and
    # honors HTTPLIB2_CA_CERTS (not SSL_CERT_FILE). The OpenShell L7 proxy
    # MITMs HTTPS with /etc/openshell-tls/ca-bundle.pem; without pointing
    # httplib2 at it, every connection fails with "self-signed certificate
    # in certificate chain". REQUESTS_CA_BUNDLE/SSL_CERT_FILE covers any
    # non-httplib2 paths.
    #
    # We deliberately do NOT set HTTPS_PROXY/HTTP_PROXY: the sandbox's
    # network namespace already routes outbound through the L7 proxy
    # transparently, and setting the env vars triggers pysocks's auto-detect
    # path inside httplib2, which then negotiates the proxy as SOCKS5 and
    # gets a 403. (Confirmed empirically 2026-06-18.)
    env = dict(os.environ)
    env["PYTHONPATH"] = "/sandbox/.hermes/pylibs"
    env.setdefault("SSL_CERT_FILE", "/etc/openshell-tls/ca-bundle.pem")
    env.setdefault("REQUESTS_CA_BUNDLE", "/etc/openshell-tls/ca-bundle.pem")
    env.setdefault("HTTPLIB2_CA_CERTS", "/etc/openshell-tls/ca-bundle.pem")
    p = subprocess.run(
        [PYTHON, GOOGLE_API, "gmail", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=env,
    )
    return p.returncode, p.stdout, p.stderr


def thread_participants(thread_id: str) -> set[str]:
    """Pull every address that has touched this thread (from/to/cc/reply_to
    on each message + any address mentioned in bodies). Used to widen the
    allowlist beyond operator+agent so legitimate reply-all goes through."""
    found: set[str] = set()
    rc, out, _ = call_gmail(["search", "", "--max", "50"], timeout=20)
    if rc != 0:
        return found
    try:
        msgs = json.loads(out or "[]")
    except json.JSONDecodeError:
        return found
    for m in msgs:
        if m.get("threadId") != thread_id:
            continue
        rc, gout, _ = call_gmail(["get", m["id"]], timeout=15)
        if rc != 0:
            continue
        try:
            full = json.loads(gout)
        except json.JSONDecodeError:
            continue
        for field in ("from", "to", "cc", "reply_to"):
            v = full.get(field) or ""
            found.update(em.group(0).lower() for em in EMAIL_RE.finditer(v))
        body = full.get("body") or full.get("snippet") or ""
        found.update(em.group(0).lower() for em in EMAIL_RE.finditer(body))
    return found


def draft_addresses(draft: dict) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for field in ("to", "cc", "bcc"):
        v = draft.get(field) or ""
        for m in EMAIL_RE.finditer(v):
            pairs.append((field, m.group(0).lower()))
    return pairs


def move(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)


def write_sidecar(path: Path, payload: dict) -> None:
    with path.open("w") as f:
        json.dump(payload, f, indent=2)


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def process(draft_path: Path) -> str:
    """Process one approved draft; return a one-line summary for Slack."""
    draft_id = draft_path.stem
    try:
        draft = json.loads(draft_path.read_text())
    except Exception as exc:
        move(draft_path, FAILED / draft_path.name)
        write_sidecar(
            FAILED / f"{draft_id}.error.json",
            {"draft_id": draft_id, "failed_at": now_iso(),
             "reason": f"unreadable draft JSON: {exc}"},
        )
        return f"⚠️ `{draft_id}` unreadable JSON — moved to failed/"

    # Build allowlist
    allow = set(OPERATOR_EMAILS) | {AGENT_EMAIL}
    tid = draft.get("thread_id")
    if tid:
        allow |= thread_participants(tid)

    pairs = draft_addresses(draft)
    bad = [(f, a) for f, a in pairs if a not in allow]
    if bad:
        move(draft_path, FAILED / draft_path.name)
        write_sidecar(
            FAILED / f"{draft_id}.error.json",
            {"draft_id": draft_id, "failed_at": now_iso(),
             "reason": "recipient allowlist violation",
             "bad_addresses": [{"field": f, "address": a} for f, a in bad],
             "allow_list": sorted(allow)},
        )
        bad_str = ", ".join(f"{f}={a}" for f, a in bad)
        return f"⚠️ `{draft_id}` REJECTED — addresses not in allowlist: {bad_str}"

    # Send. google_api.py gmail send takes --to/--cc/--subject/--body/--thread-id/--from
    args = ["send", "--to", draft["to"], "--subject", draft["subject"],
            "--body", draft["body"]]
    if draft.get("cc"):
        args += ["--cc", draft["cc"]]
    if draft.get("thread_id"):
        args += ["--thread-id", draft["thread_id"]]
    if draft.get("from"):
        args += ["--from", draft["from"]]
    if draft.get("html"):
        args += ["--html"]
    rc, out, err = call_gmail(args, timeout=60)
    if rc != 0 or '"status": "sent"' not in out:
        move(draft_path, FAILED / draft_path.name)
        write_sidecar(
            FAILED / f"{draft_id}.error.json",
            {"draft_id": draft_id, "failed_at": now_iso(),
             "reason": "gmail send failed",
             "rc": rc, "stdout": out[-500:], "stderr": err[-500:]},
        )
        return f"❌ `{draft_id}` send failed (rc={rc}) — moved to failed/"

    try:
        msg_id = json.loads(out).get("id", "?")
    except json.JSONDecodeError:
        msg_id = "?"
    move(draft_path, SENT / draft_path.name)
    write_sidecar(
        SENT / f"{draft_id}.sent.json",
        {"draft_id": draft_id, "gmail_message_id": msg_id, "sent_at": now_iso()},
    )
    return f"✉️ Sent `{draft_id}` → {draft['to']} (subject: {draft['subject']!r}, gmail_id=`{msg_id}`)"


def main() -> int:
    # Run on every tick: the gateway can refresh the token at any time and
    # write `expiry` back as an int, which any subsequent cold reader (our
    # gmail subprocess, the heartbeat script, etc.) crashes on. Cheap;
    # no-op when expiry is already a string or None.
    normalize_token()

    if not APPROVED.exists():
        return 0  # silent — nothing to send
    pending = sorted(p for p in APPROVED.glob("*.json") if p.is_file())
    if not pending:
        return 0  # silent

    lines: list[str] = []
    for p in pending:
        try:
            lines.append(process(p))
        except Exception as exc:
            lines.append(f"⚠️ `{p.stem}` unexpected error: {exc!r}")

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
