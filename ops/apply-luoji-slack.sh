#!/usr/bin/env bash
# Write luoji's channels.slack block + binding into his sandbox openclaw.json.
#
# luoji's Slack was originally applied BY HAND (2026-09-01) and existed only as
# prose in docs/RUNBOOK-second-slack-app.md. This script reproduces it from
# ~/.openclaw-config-backups/luoji/openclaw.json.pre-slackplugin-20260901T120950Z,
# so a sandbox rebuild no longer means manual transcription.
#
# Same shape as ops/apply-cecat-slack.sh — only the account name, tokens and
# channel ID differ. Idempotent: re-running overwrites the slack block and the
# slack binding, leaving everything else in the config untouched.
#
# Tokens come from ~/.openclaw-secrets/luoji-slack.env (mode 600, host-side).
#
# Egress is a SEPARATE prerequisite, not done here: luoji reaches Slack as
# /usr/local/bin/node, so bringup/50-openshell-policies/luoji-slack-egress.yaml
# must already be on his sandbox or the adapter is denied at the L7 proxy.
# Apply it with `bash ops/apply-policies.sh luoji` — the agent argument is
# mandatory and `luoji-*.yaml` is owned by luoji, so that pushes his preset and
# nothing else. (Equivalently by hand:
# `openshell sandbox policy add luoji --from-file <yaml> --yes` after
# `source ops/luoji-env.sh`.)
#
# Run: bash ops/apply-luoji-slack.sh
set -eu

AGENT=luoji
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
            "name": "LuoJi",
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
