#!/usr/bin/env bash
# End-to-end smoke test after the bringup phases. Idempotent; safe to re-run.

set -eu
export PATH="$HOME/.local/bin:$PATH"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

CONTAINER=$(docker ps --format '{{.Names}}' | grep '^openshell-gandalf-' | head -1 || true)
if [ -z "$CONTAINER" ]; then
  red "✗ No gandalf sandbox container is running. Re-run the install (step 10)."
  exit 1
fi
green "✓ Sandbox container: $CONTAINER"

# 1. Inference round-trip
echo ""
echo "=== 1. inference round-trip (vLLM via OpenShell router) ==="
REPLY=$(curl -sS -m 30 -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"Respond with exactly: PONG"}],"max_tokens":5}' \
  2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"])' 2>&1 || echo "FAIL")
if [[ "$REPLY" == *PONG* ]]; then green "✓ inference: $REPLY"; else red "✗ inference: $REPLY"; fi

# 2. Gmail
echo ""
echo "=== 2. gmail search (existence-of-mailbox check) ==="
GMAIL=$(docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs "$CONTAINER" \
  /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/google_api.py gmail search "is:unread" --max 1 2>&1 | head -5)
if echo "$GMAIL" | grep -qE '"id"|^\[\]$'; then green "✓ gmail: returned JSON ($(echo "$GMAIL" | head -c 80)…)"; else red "✗ gmail: $GMAIL"; fi

# 3. Drive
echo ""
echo "=== 3. drive search ==="
DRIVE=$(docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs "$CONTAINER" \
  /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/google_api.py drive search "." --max 1 2>&1 | head -5)
if echo "$DRIVE" | grep -qE '"id"|^\[\]$'; then green "✓ drive: returned JSON"; else red "✗ drive: $DRIVE"; fi

# 4. Slack bot identity (does the token Slack-auth?)
echo ""
echo "=== 4. slack auth.test ==="
if [ -f ~/.hermes/.env ]; then
  set -a; . ~/.hermes/.env; set +a
  SLACK=$(curl -sS -m 10 -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test 2>&1)
  if echo "$SLACK" | grep -q '"ok":true'; then
    USER=$(echo "$SLACK" | python3 -c 'import json,sys;print(json.load(sys.stdin)["user"])')
    green "✓ slack: bot identity = $USER"
  else
    red "✗ slack: $SLACK"
  fi
else
  yellow "○ slack: ~/.hermes/.env not present, skipping"
fi

# 5. Cron jobs
echo ""
echo "=== 5. hermes cron list ==="
CRON=$(docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes "$CONTAINER" /usr/local/bin/hermes cron list 2>&1 | grep -E 'active|paused' | wc -l)
if [ "$CRON" -gt 0 ]; then green "✓ cron: $CRON job(s) scheduled"; else yellow "○ cron: 0 jobs (run 'bash ../ops/apply-cron.sh' to load cron.jobs from ~/.hermes/config.yaml)"; fi

echo ""
green "Smoke tests complete."
