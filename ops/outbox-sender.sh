#!/usr/bin/env bash
# Outbox sender — runs on the same 5-minute cron as the processor.
# Reads each /sandbox/.hermes/outbox/approved/*.json, sends via gmail send,
# moves to /sandbox/.hermes/outbox/sent/ on success.
# On send failure: moves to /sandbox/.hermes/outbox/failed/ with an error sidecar.
#
# Runs as the host user. Does NOT see Gandalf's prompt — only the approved JSON.
# That isolation is the security property.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
load_hermes_env
require_hermes_config

CONTAINER=$(gandalf_container)

# Make sure failed/ exists
docker exec -u sandbox "$CONTAINER" sh -c 'mkdir -p /sandbox/.hermes/outbox/failed' || true

APPROVED=$(docker exec -u sandbox "$CONTAINER" sh -c '
  for f in /sandbox/.hermes/outbox/approved/*.json; do
    [ -f "$f" ] || continue
    echo "$f"
  done
' 2>/dev/null || echo "")

[ -n "$APPROVED" ] || { info "No approved drafts to send."; exit 0; }

echo "$APPROVED" | while IFS= read -r path; do
  [ -n "$path" ] || continue
  draft_id=$(basename "$path" .json)
  note "Sending: $draft_id"

  # Read the JSON
  draft=$(docker exec -u sandbox "$CONTAINER" cat "$path" 2>/dev/null)
  if [ -z "$draft" ]; then
    warn "Could not read $path"
    continue
  fi

  # ── Recipient validation (deterministic guard against address-hallucination) ──
  # Build an allowlist of addresses the agent legitimately knows:
  #   - Operator emails from ~/.hermes/config.yaml
  #   - Agent's own account (so reply-all that includes it gets caught & stripped, not rejected)
  #   - Any address that appears in the referenced thread (if thread_id is set)
  # Then check every `to`/`cc` address in the draft against the allowlist.
  # Any unknown address → reject the draft, write a .error.json with the bad
  # addresses, DM the operator, do NOT call gmail send.
  VALIDATION=$(python3 - "$HERMES_CONFIG" "$draft" "$CONTAINER" <<'PYEOF'
import json, os, re, subprocess, sys, yaml
cfg_path, draft_raw, container = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = yaml.safe_load(open(cfg_path))
draft = json.loads(draft_raw)

EMAIL_RE = re.compile(r"[\w.+-]+@[\w.-]+\.\w+")

# Build allowlist
allow = set()
op = cfg.get("operator", {})
for k in ("primary_email", "work_email"):
    v = op.get(k)
    if v: allow.add(v.lower())
agent = (cfg.get("google", {}).get("agent_account") or "").lower()
if agent: allow.add(agent)

# Pull every message in the referenced thread, scan headers + body for addresses.
# Gmail doesn't expose a thread:<id> search operator via this wrapper, so:
#   1. List recent received messages, filter to ones with matching threadId
#   2. For each match, gmail get <id> to read headers + body
thread_id = draft.get("thread_id")
if thread_id:
    try:
        # Get recent inbox messages and their thread IDs
        out = subprocess.run(
            ["docker","exec","-u","sandbox",
             "-e","HERMES_HOME=/sandbox/.hermes",
             "-e","PYTHONPATH=/sandbox/.hermes/pylibs",
             container,
             "/opt/hermes/.venv/bin/python",
             "/opt/hermes/skills/productivity/google-workspace/scripts/google_api.py",
             "gmail","search","","--max","50"],
            capture_output=True, text=True, timeout=20, check=False,
        )
        msgs = json.loads(out.stdout or "[]")
        matching_ids = [m["id"] for m in msgs if m.get("threadId") == thread_id]
        for mid in matching_ids:
            r = subprocess.run(
                ["docker","exec","-u","sandbox",
                 "-e","HERMES_HOME=/sandbox/.hermes",
                 "-e","PYTHONPATH=/sandbox/.hermes/pylibs",
                 container,
                 "/opt/hermes/.venv/bin/python",
                 "/opt/hermes/skills/productivity/google-workspace/scripts/google_api.py",
                 "gmail","get",mid],
                capture_output=True, text=True, timeout=15, check=False,
            )
            try:
                msg = json.loads(r.stdout)
            except Exception:
                continue
            for field in ("from","to","cc","reply_to"):
                v = msg.get(field) or ""
                for em in EMAIL_RE.finditer(v):
                    allow.add(em.group(0).lower())
            body = msg.get("body") or msg.get("snippet") or ""
            for em in EMAIL_RE.finditer(body):
                allow.add(em.group(0).lower())
    except Exception:
        pass

# Extract addresses from draft.to + draft.cc
draft_addrs = []
for field in ("to","cc","bcc"):
    v = draft.get(field) or ""
    for m in EMAIL_RE.finditer(v):
        draft_addrs.append((field, m.group(0).lower()))

bad = [(field, addr) for field, addr in draft_addrs if addr not in allow]
result = {
    "ok": len(bad) == 0,
    "draft_addrs": [a for _,a in draft_addrs],
    "allow_list": sorted(allow),
    "bad_addrs": [{"field": f, "address": a} for f,a in bad],
}
print(json.dumps(result))
PYEOF
)
  # Parse validation result; pass via argv to dodge stdin/heredoc collisions.
  VR_OK=$(python3 -c 'import json,sys; print("yes" if json.loads(sys.argv[1]).get("ok") else "no")' "$VALIDATION")
  if [ "$VR_OK" = "no" ]; then
    BAD=$(python3 -c '
import json,sys
d = json.loads(sys.argv[1])
print(", ".join(b["field"] + "=" + b["address"] for b in d["bad_addrs"]))
' "$VALIDATION")
    ALLOW=$(python3 -c '
import json,sys
print(", ".join(json.loads(sys.argv[1])["allow_list"]))
' "$VALIDATION")
    warn "Rejecting $draft_id — addresses not in allowlist: $BAD"
    docker exec -u sandbox "$CONTAINER" sh -c "
      mv $path /sandbox/.hermes/outbox/failed/${draft_id}.json
      cat > /sandbox/.hermes/outbox/failed/${draft_id}.error.json <<JSONEOF
{\"draft_id\": \"$draft_id\", \"failed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"reason\": \"Recipient allowlist violation\", \"bad_addresses\": \"$BAD\", \"allowed\": \"$ALLOW\"}
JSONEOF"
    # DM the operator about the rejection
    DM_CHANNEL="D0BBDHYCWPK"
    curl -sS -X POST \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$(python3 -c "import json; print(json.dumps({'channel':'$DM_CHANNEL','text':'⚠️ *Draft REJECTED by recipient validator* \`$draft_id\`\nBad addresses: $BAD\n(Gandalf likely hallucinated. Failed-draft + .error.json kept in outbox/failed/ for review.)','unfurl_links':False}))")" \
      https://slack.com/api/chat.postMessage >/dev/null 2>&1 || true
    continue
  fi

  # Build argv for `gmail send` via Python (handles quoting/escaping cleanly)
  ARGS=$(echo "$draft" | python3 -c '
import json, sys, shlex
d = json.load(sys.stdin)
parts = ["--to", d["to"], "--subject", d["subject"], "--body", d["body"]]
if d.get("cc"): parts += ["--cc", d["cc"]]
if d.get("thread_id"): parts += ["--thread-id", d["thread_id"]]
if d.get("from"): parts += ["--from", d["from"]]
if d.get("html"): parts += ["--html"]
print(" ".join(shlex.quote(p) for p in parts))
')

  # Send via the Hermes google_api.py wrapper (which reads /sandbox/.hermes/google_token.json)
  SEND=$(docker exec -u sandbox \
    -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs \
    "$CONTAINER" \
    sh -c "/opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/google_api.py gmail send $ARGS" 2>&1)

  if echo "$SEND" | grep -q '"status": "sent"'; then
    MSG_ID=$(echo "$SEND" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "?")
    # Move approved/ → sent/, write a sidecar with the message id
    docker exec -u sandbox "$CONTAINER" sh -c "
      mv $path /sandbox/.hermes/outbox/sent/${draft_id}.json && \
      cat > /sandbox/.hermes/outbox/sent/${draft_id}.sent.json <<JSONEOF
{\"draft_id\": \"$draft_id\", \"gmail_message_id\": \"$MSG_ID\", \"sent_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
JSONEOF"
    info "Sent $draft_id (message_id=$MSG_ID)"

    # DM the operator a one-line confirmation
    DM_CHANNEL="D0BBDHYCWPK"   # could resolve via conversations.open, but cached for speed
    TO=$(echo "$draft" | python3 -c 'import json,sys; print(json.load(sys.stdin)["to"])')
    SUBJ=$(echo "$draft" | python3 -c 'import json,sys; print(json.load(sys.stdin)["subject"])')
    curl -sS -X POST \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$(python3 -c "import json; print(json.dumps({'channel':'$DM_CHANNEL','text':'✉️ *Sent* \`$draft_id\` → $TO\nSubject: $SUBJ\nGmail msg id: \`$MSG_ID\`','unfurl_links':False}))")" \
      https://slack.com/api/chat.postMessage >/dev/null 2>&1 || true
  else
    warn "Send failed for $draft_id: $SEND"
    docker exec -u sandbox "$CONTAINER" sh -c "
      mv $path /sandbox/.hermes/outbox/failed/${draft_id}.json && \
      cat > /sandbox/.hermes/outbox/failed/${draft_id}.error.json <<JSONEOF
{\"draft_id\": \"$draft_id\", \"failed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"error\": $(echo "$SEND" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}
JSONEOF"
  fi
done
