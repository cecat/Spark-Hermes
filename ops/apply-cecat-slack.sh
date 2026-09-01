#!/usr/bin/env bash
# Write cecat's channels.slack block + binding into her sandbox openclaw.json.
#
# Mirrors luoji's live config exactly (read back from his sandbox 2026-09-01);
# only the account name, tokens and channel ID differ. Idempotent: re-running
# overwrites the slack block and the slack binding, leaving everything else in
# the config untouched.
#
# Tokens come from ~/.openclaw-secrets/cecat-slack.env (mode 600, host-side).
# SLACK_USER_TOKEN is deliberately NOT used — OpenClaw has no userToken field.
#
# Run: bash ops/apply-cecat-slack.sh
set -eu

AGENT=cecat
SECRETS="$HOME/.openclaw-secrets/${AGENT}-slack.env"
CFG=/sandbox/.openclaw/openclaw.json

[ -f "$SECRETS" ] || { echo "missing $SECRETS" >&2; exit 1; }
set -a; . "$SECRETS"; set +a
: "${SLACK_BOT_TOKEN:?}" "${SLACK_APP_TOKEN:?}" "${SLACK_CHANNEL_ID:?}"

CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
[ -n "$CON" ] || { echo "no running sandbox for $AGENT" >&2; exit 1; }

# Build the patch on the host, apply it inside the sandbox with python3.
# Passing values via env avoids quoting the tokens into a shell string.
docker exec -u sandbox -i \
    -e SLACK_BOT_TOKEN -e SLACK_APP_TOKEN -e SLACK_CHANNEL_ID \
    -e AGENT="$AGENT" -e CFG="$CFG" \
    "$CON" python3 - <<'PY'
import json, os, shutil

cfg = os.environ["CFG"]
agent = os.environ["AGENT"]
shutil.copy(cfg, cfg + ".bak")

with open(cfg) as f:
    d = json.load(f)

d.setdefault("channels", {})["slack"] = {
    "enabled": True,
    "mode": "socket",
    "groupPolicy": "allowlist",
    "dmPolicy": "open",
    "dm": {"enabled": True},
    "streaming": {"mode": "off"},
    "historyLimit": 20,
    "dmHistoryLimit": 20,
    "accounts": {
        agent: {
            "name": "CeCat",
            "botToken": os.environ["SLACK_BOT_TOKEN"],
            "appToken": os.environ["SLACK_APP_TOKEN"],
        }
    },
    "channels": {
        os.environ["SLACK_CHANNEL_ID"]: {"requireMention": True, "enabled": True}
    },
    "allowFrom": ["*"],
}

# agentId is "main", not the agent name: one sandbox per plane, and OpenClaw
# calls its single agent "main". A binding naming the agent matches nothing.
bindings = [b for b in (d.get("bindings") or [])
            if (b.get("match") or {}).get("channel") != "slack"]
bindings.append({"agentId": "main",
                 "match": {"channel": "slack", "accountId": agent}})
d["bindings"] = bindings

d.setdefault("plugins", {}).setdefault("entries", {})["slack"] = {"enabled": True}

with open(cfg, "w") as f:
    json.dump(d, f, indent=2)

print("slack account:", list(d["channels"]["slack"]["accounts"]))
print("bindings:", json.dumps(d["bindings"]))
print("plugins:", json.dumps(d["plugins"]["entries"]))
PY

echo "--- restarting gateway (SIGTERM; supervisor respawns) ---"
# `openclaw gateway restart` drives systemd, which is absent in the sandbox.
docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' || true
sleep 8
docker exec -u sandbox "$CON" sh -c 'pgrep -af openclaw-gateway | head -3' || echo "gateway not back yet"
