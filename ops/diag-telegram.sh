#!/usr/bin/env bash
# Diagnose why a Telegram DM to an OpenClaw agent gets no reply.
#
# Read-only. Prints NO secrets — token length only, never the value.
#
# Run: bash ops/diag-telegram.sh            (both agents)
#      bash ops/diag-telegram.sh cecat      (one agent)
set -u

AGENTS="${1:-cecat luoji}"

for AGENT in $AGENTS; do
  echo "════════════════════════════════════════════"
  echo "  $AGENT"
  echo "════════════════════════════════════════════"

  CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
  if [ -z "$CON" ]; then
    echo "  NO RUNNING SANDBOX"
    continue
  fi

  echo "--- config as the gateway sees it ---"
  # -i is REQUIRED: without it stdin is not attached and python3 silently reads
  # an empty script, printing nothing. That looked like "blocked" for a full round.
  docker exec -u sandbox -i "$CON" python3 - <<'PY'
import json
try:
    d = json.load(open("/sandbox/.openclaw/openclaw.json"))
except Exception as e:
    print("  could not read config:", e); raise SystemExit

tg = (d.get("channels") or {}).get("telegram") or {}
print("  channel enabled :", tg.get("enabled"))
accts = tg.get("accounts") or {}
print("  accounts        :", list(accts))
for name, a in accts.items():
    print(f"  [{name}]")
    print("    enabled     :", a.get("enabled"))
    print("    dmPolicy    :", a.get("dmPolicy", "(unset -> manual pairing)"))
    print("    allowFrom   :", a.get("allowFrom", "(unset)"))
    if a.get("allowFrom"):
        for v in a["allowFrom"]:
            print(f"        entry {v!r}  type={type(v).__name__}")
    print("    groupPolicy :", a.get("groupPolicy"))
    print("    botToken    : length", len(a.get("botToken", "")), "(value not shown)")

print("  plugins.telegram:", (d.get("plugins", {}).get("entries", {}) or {}).get("telegram"))
print("  bindings:")
for b in (d.get("bindings") or []):
    print("   ", json.dumps(b))
PY

  echo "--- adapter startup (which bot is it?) ---"
  docker logs --tail 500000 -t "$CON" 2>&1 \
    | grep 'gateway-log' | grep -i 'telegram' \
    | grep -viE 'menu text|budget' | tail -4 | sed 's/^/  /'

  echo "--- inbound telegram messages seen by the gateway ---"
  HITS=$(docker logs --tail 500000 -t "$CON" 2>&1 \
    | grep 'gateway-log' | grep -iE 'telegram' \
    | grep -iE 'inbound|dm |message from|reject|denied|not allowed|ignor|unauthor' | tail -8)
  if [ -z "$HITS" ]; then
    echo "  NONE — no inbound telegram message reached the agent."
  else
    echo "$HITS" | sed 's/^/  /'
  fi

  echo "--- did Telegram deliver anything? (poll gap pattern) ---"
  echo "  A long-poll returns at ~30s when EMPTY. A short gap means a message arrived."
  echo -n "  last 30 gaps (seconds): "
  docker logs --tail 500000 -t "$CON" 2>&1 | grep 'getUpdates' | tail -31 \
    | sed 's/\(.*T\)\([0-9:]*\)\..*/\2/' \
    | awk -F: 'NR>1{d=($3-p)+60*($2-q); if(d<0)d+=3600; printf "%d ", d} {p=$3; q=$2}'
  echo

  echo "--- ingress spool (where polled updates are staged) ---"
  docker exec -u sandbox -i "$CON" sh -s "$AGENT" <<'SH'
d=/sandbox/.openclaw/telegram/ingress-spool-$1
if [ -d "$d" ]; then
  echo "  $d"
  echo "  files: $(find "$d" -type f 2>/dev/null | wc -l)"
  find "$d" -type f 2>/dev/null | head -5 | sed 's/^/    /'
else
  echo "  spool dir not found: $d"
fi
SH

  echo "--- gateway errors since last restart ---"
  docker logs --tail 500000 -t "$CON" 2>&1 | grep 'gateway-log' \
    | grep -iE 'error|exception|failed|refus|cannot|unhandled' \
    | grep -viE 'healthMonitor|menu text' | tail -6 | sed 's/^/  /'

  echo "--- any telegram egress DENY? ---"
  D=$(docker logs --tail 500000 -t "$CON" 2>&1 | grep -i 'telegram' | grep -i 'denied' | tail -3)
  [ -z "$D" ] && echo "  none (egress is fine)" || echo "$D" | sed 's/^/  /'
  echo
done

echo "════════════════════════════════════════════"
echo "HOW TO READ THIS"
echo "════════════════════════════════════════════"
echo "  If allowFrom entries show type=str but Telegram sends numeric IDs,"
echo "  the allowlist will never match and DMs are silently dropped."
echo "  If a short poll gap appears but inbound shows NONE, the message"
echo "  reached the adapter and was discarded before the agent saw it."
echo "  If dmPolicy is unset, the bot requires manual pairing first."
