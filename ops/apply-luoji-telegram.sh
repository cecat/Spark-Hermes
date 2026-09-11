#!/usr/bin/env bash
# Write luoji's channels.telegram block + binding into his sandbox openclaw.json.
#
# Same shape as ops/apply-cecat-telegram.sh — only AGENT differs. Direct
# analogue of ops/apply-luoji-slack.sh: same container discovery, same
# embedded-python patch, same SIGTERM restart. Idempotent: re-running overwrites
# the telegram block and the telegram binding, leaving everything else in the
# config untouched.
#
# The block itself mirrors NemoClaw v0.0.108's own OpenClaw Telegram render
# fragment (src/lib/messaging/channels/telegram/manifest.ts, id
# "telegram-openclaw-channel"), so the hand-applied config matches what the
# generator would have produced. Two deliberate departures from that fragment,
# both to match the local Slack pattern:
#   - the account key is the agent name, not "default", so the binding's
#     accountId reads the same as it does for slack;
#   - the botToken is the literal value from the secrets file, not an
#     `openshell:resolve:env:` placeholder — that indirection is populated by
#     the onboarding credential provider, which we are not running.
#
# Token comes from ~/.openclaw-secrets/luoji-telegram.env (mode 600, host-side):
#   TELEGRAM_BOT_TOKEN=...        required, from @BotFather
#   TELEGRAM_ALLOWED_IDS=...      optional, comma-separated numeric user IDs
#                                 (get yours from @userinfobot). If set, DMs are
#                                 restricted to those IDs. If unset, dmPolicy is
#                                 omitted and the bot requires manual pairing —
#                                 upstream's default, and not a failure.
#
# Egress is a SEPARATE prerequisite, not done here: luoji reaches Telegram as
# /usr/local/bin/node, so bringup/50-openshell-policies/luoji-telegram-egress.yaml
# must already be on his sandbox or the adapter is denied at the L7 proxy.
# Apply it with:
#   bash ops/nmc.sh luoji policy add --from-file bringup/50-openshell-policies/luoji-telegram-egress.yaml --yes
# Do NOT use ops/apply-policies.sh — it is hardcoded to gandalf.
#
# The @openclaw/telegram plugin needs no install: unlike slack, it is bundled in
# the OpenShell image.
#
# WARNING: this restarts the gateway inside the sandbox.
#
# Run: bash ops/apply-luoji-telegram.sh
set -eu

AGENT=luoji
SECRETS="$HOME/.openclaw-secrets/${AGENT}-telegram.env"
CFG=/sandbox/.openclaw/openclaw.json

[ -f "$SECRETS" ] || { echo "missing $SECRETS" >&2; exit 1; }
set -a; . "$SECRETS"; set +a
: "${TELEGRAM_BOT_TOKEN:?}"
TELEGRAM_ALLOWED_IDS="${TELEGRAM_ALLOWED_IDS:-}"

CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
[ -n "$CON" ] || { echo "no running sandbox for $AGENT" >&2; exit 1; }

# Build the patch on the host, apply it inside the sandbox with python3.
# Passing values via env avoids quoting the token into a shell string.
docker exec -u sandbox -i \
    -e TELEGRAM_BOT_TOKEN -e TELEGRAM_ALLOWED_IDS \
    -e AGENT="$AGENT" -e CFG="$CFG" \
    "$CON" python3 - <<'PY'
import json, os, shutil

cfg = os.environ["CFG"]
agent = os.environ["AGENT"]
shutil.copy(cfg, cfg + ".bak")

with open(cfg) as f:
    d = json.load(f)

# The sandbox already routes through the L7 proxy, but upstream's OpenClaw
# fragment sets this explicitly per account, so honour whatever the config
# already declares globally rather than inventing a second value.
proxy_url = (d.get("proxy") or {}).get("proxyUrl") or "http://10.200.0.1:3128"

account = {
    "enabled": True,
    "botToken": os.environ["TELEGRAM_BOT_TOKEN"],
    "healthMonitor": {"enabled": False},
    "proxy": proxy_url,
    # Group chats: reply only when @mentioned. Telegram also needs privacy mode
    # DISABLED in @BotFather (/setprivacy -> Disable) before a bot sees group
    # messages at all, and the bot re-added to each group afterwards.
    "groupPolicy": "open",
}

# Telegram user IDs are INTEGERS on the wire. Writing them as JSON strings makes
# the allowlist compare "123" against 123, which never matches — the DM is then
# dropped silently, with no error and no inbound log line. Emit both forms so the
# comparison succeeds whichever the adapter uses.
_raw = [i.strip() for i in os.environ.get("TELEGRAM_ALLOWED_IDS", "").split(",") if i.strip()]
ids = []
for i in _raw:
    ids.append(int(i) if i.lstrip("-").isdigit() else i)
    if i.lstrip("-").isdigit():
        ids.append(i)
if ids:
    account["dmPolicy"] = "allowlist"
    account["allowFrom"] = ids

d.setdefault("channels", {})["telegram"] = {
    "enabled": True,
    "accounts": {agent: account},
    "groups": {"*": {"requireMention": True}},
}

# agentId is "main", not the agent name: one sandbox per plane, and OpenClaw
# calls its single agent "main". A binding naming the agent matches nothing.
bindings = [b for b in (d.get("bindings") or [])
            if (b.get("match") or {}).get("channel") != "telegram"]
bindings.append({"agentId": "main",
                 "match": {"channel": "telegram", "accountId": agent}})
d["bindings"] = bindings

d.setdefault("plugins", {}).setdefault("entries", {})["telegram"] = {"enabled": True}

with open(cfg, "w") as f:
    json.dump(d, f, indent=2)

print("telegram account:", list(d["channels"]["telegram"]["accounts"]))
print("dm access:", "allowlist" if ids else "pairing (no TELEGRAM_ALLOWED_IDS set)")
print("bindings:", json.dumps(d["bindings"]))
print("plugins:", json.dumps(d["plugins"]["entries"]))
PY

echo "--- restarting gateway (SIGTERM; supervisor respawns) ---"
# `openclaw gateway restart` drives systemd, which is absent in the sandbox.
docker exec -u sandbox "$CON" sh -c 'pkill -TERM -f openclaw-gateway' || true
sleep 8
docker exec -u sandbox "$CON" sh -c 'pgrep -af openclaw-gateway | head -3' || echo "gateway not back yet"
