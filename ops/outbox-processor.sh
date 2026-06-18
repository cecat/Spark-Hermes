#!/usr/bin/env bash
# Outbox processor — runs on a 5-minute cron.
# - Reads pending drafts from /sandbox/.hermes/outbox/pending/
# - Posts each as a Slack DM to the operator with ✅ ❌ reactions seeded
# - Watches for reactions on previously-posted drafts; moves files accordingly
#
# Idempotent. Drafts already posted (tracked by .posted-ts files alongside them)
# get a "still pending" re-ping after 30 min if no reaction yet.
#
# Runs as the host user. Reads/writes inside the sandbox via `docker exec`.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
load_hermes_env
require_hermes_config

CONTAINER=$(gandalf_container)

OPERATOR_ID=$(hermes_cfg slack.allowed_users | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
[ -n "$OPERATOR_ID" ] || fail "Could not extract slack.allowed_users[0].id from $HERMES_CONFIG"

DM_RESP=$(curl -sS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d "{\"users\":\"$OPERATOR_ID\"}" \
  https://slack.com/api/conversations.open 2>/dev/null)
DM_CHANNEL=$(echo "$DM_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("channel",{}).get("id",""))' 2>/dev/null)
[ -n "$DM_CHANNEL" ] || fail "Could not open DM with operator $OPERATOR_ID: $DM_RESP"

# Ensure the outbox tree exists inside the sandbox. (sh, not bash — no brace expansion)
docker exec -u sandbox "$CONTAINER" sh -c '
  for d in pending approved rejected sent failed posted; do
    mkdir -p "/sandbox/.hermes/outbox/$d"
  done
' || fail "Could not initialize outbox tree"

# Repost-threshold: if a draft is still pending after this many seconds, re-ping.
REPING_AFTER=1800   # 30 min

# ── 1. Handle reactions on previously-posted drafts ─────────────────
# Each posted draft has a sidecar file /sandbox/.hermes/outbox/posted/<id>.json
# containing the Slack message ts. Poll Slack for reactions on that ts.

POSTED_JSON=$(docker exec -u sandbox "$CONTAINER" sh -c '
  for f in /sandbox/.hermes/outbox/posted/*.json; do
    [ -f "$f" ] || continue
    echo "=====$f====="
    cat "$f"
  done
' 2>/dev/null || echo "")

if [ -n "$POSTED_JSON" ]; then
  python3 - "$DM_CHANNEL" "$SLACK_BOT_TOKEN" "$POSTED_JSON" <<'PYEOF'
import json, os, re, subprocess, sys, urllib.parse, urllib.request

dm_channel, bot_token, text = sys.argv[1], sys.argv[2], sys.argv[3]

# Parse the concat-stream of "=====<path>=====\n<json>\n" records
records = []
parts = re.split(r'=====(/[^=]+?)=====\n', text)
i = 1
while i < len(parts):
    path = parts[i]
    body = parts[i+1] if i+1 < len(parts) else ''
    try:
        records.append((path, json.loads(body)))
    except json.JSONDecodeError:
        pass
    i += 2

def slack_get(method, **params):
    url = f"https://slack.com/api/{method}?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bot_token}"})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())

def sb_exec(*cmd):
    container = subprocess.run(["docker","ps","--format","{{.Names}}"],
        capture_output=True, text=True, check=True).stdout
    container = next((l for l in container.splitlines() if l.startswith("openshell-gandalf-")), None)
    return subprocess.run(["docker","exec","-u","sandbox", container] + list(cmd),
        capture_output=True, text=True)

for path, meta in records:
    ts = meta.get("slack_message_ts")
    draft_id = meta.get("draft_id")
    if not ts or not draft_id:
        continue
    r = slack_get("reactions.get", channel=dm_channel, timestamp=ts)
    if not r.get("ok"):
        continue
    reactions = {x["name"] for x in (r.get("message") or {}).get("reactions", [])}
    action = None
    if "white_check_mark" in reactions or "heavy_check_mark" in reactions or "+1" in reactions:
        action = "approved"
    elif "x" in reactions or "no_entry" in reactions or "-1" in reactions:
        action = "rejected"
    if not action:
        continue
    src = f"/sandbox/.hermes/outbox/pending/{draft_id}.json"
    dst = f"/sandbox/.hermes/outbox/{action}/{draft_id}.json"
    res = sb_exec("sh","-c", f"[ -f {src} ] && mv {src} {dst} && rm -f {path} && echo moved || echo missing")
    print(f"  {draft_id}: {action} ({res.stdout.strip()})")
PYEOF
fi

# ── 2. Find pending drafts and post the ones that haven't been posted yet ───
PENDING=$(docker exec -u sandbox "$CONTAINER" sh -c '
  for f in /sandbox/.hermes/outbox/pending/*.json; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .json)
    posted=/sandbox/.hermes/outbox/posted/${id}.json
    if [ -f "$posted" ]; then
      # Check age — re-ping if older than threshold
      age=$(($(date +%s) - $(stat -c %Y "$posted")))
      if [ "$age" -lt 1800 ]; then
        continue
      fi
      echo "REPING===$f"
    else
      echo "NEW===$f"
    fi
  done
' 2>/dev/null || echo "")

[ -n "$PENDING" ] || { info "No new pending drafts."; exit 0; }

echo "$PENDING" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  kind="${line%%===*}"
  path="${line#*===}"
  draft_id=$(basename "$path" .json)

  # Read the draft JSON
  draft=$(docker exec -u sandbox "$CONTAINER" cat "$path" 2>/dev/null)
  if [ -z "$draft" ]; then
    warn "Could not read $path"
    continue
  fi

  # Build the Slack message. Pass draft as argv (NOT stdin) — the outer
  # `while read` loop already consumed stdin in this subshell.
  MSG=$(python3 - "$DM_CHANNEL" "$kind" "$draft_id" "$draft" <<'PYEOF'
import json, sys
channel, kind, draft_id, raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
draft = json.loads(raw)
prefix = "🔁 *Still pending* — " if kind == "REPING" else "📬 *Draft pending* — "
text = (
    f"{prefix}react ✅ to approve, ❌ to reject\n"
    f"`{draft_id}`\n"
    f"*To:* {draft.get('to','?')}\n"
    + (f"*Cc:* {draft.get('cc')}\n" if draft.get('cc') else "")
    + (f"*Thread:* `{draft.get('thread_id')}`\n" if draft.get('thread_id') else "")
    + f"*Subject:* {draft.get('subject','?')}\n"
    + f"*Reason:* {draft.get('reason','(none given)')}\n"
    + "—— body ——\n"
    + draft.get('body','(empty)').strip()
)
print(json.dumps({"channel": channel, "text": text, "unfurl_links": False}))
PYEOF
)

  resp=$(curl -sS -X POST \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$MSG" \
    https://slack.com/api/chat.postMessage 2>/dev/null)

  ok=$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null)
  ts=$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ts",""))' 2>/dev/null)

  if [ "$ok" = "True" ] && [ -n "$ts" ]; then
    info "Posted $draft_id (ts=$ts)"
    # Record posted-marker (used by next tick to look up the message ts when checking reactions)
    docker exec -u sandbox "$CONTAINER" sh -c "
      cat > /sandbox/.hermes/outbox/posted/${draft_id}.json <<JSONEOF
{\"draft_id\": \"$draft_id\", \"slack_message_ts\": \"$ts\", \"posted_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
JSONEOF"
  else
    warn "Failed to post $draft_id: $resp"
  fi
done
