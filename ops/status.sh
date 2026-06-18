#!/usr/bin/env bash
# Health check for Gandalf. Same shape as bringup/60-smoke-tests.sh but quieter
# on success — designed to be run periodically.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
load_hermes_env

CONTAINER=$(gandalf_container)
note "Container: $CONTAINER"

# 1. Sandbox phase (openshell colorizes output; strip ANSI before comparing)
PHASE=$(openshell sandbox list 2>/dev/null | awk '/^gandalf/ {print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
[ "$PHASE" = "Ready" ] && info "Sandbox phase: Ready" || fail "Sandbox phase: ${PHASE:-unknown}"

# 2. Inference round-trip
REPLY=$(curl -sS -m 30 -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"reply with exactly: OK"}],"max_tokens":3}' \
  2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"].strip())' 2>/dev/null || echo "FAIL")
if [[ "$REPLY" == *OK* ]]; then info "Inference: $REPLY"; else fail "Inference: $REPLY"; fi

# 3. Google token freshness
if sb_exec /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/setup.py --check 2>&1 | grep -q AUTHENTICATED; then
  info "Google: token AUTHENTICATED"
else
  warn "Google: token NOT authenticated — run bash ops/reauth-google.sh"
fi

# 4. Slack token still works
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  SLACK=$(curl -sS -m 10 -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test 2>/dev/null)
  if echo "$SLACK" | grep -q '"ok":true'; then
    USER=$(echo "$SLACK" | python3 -c 'import json,sys;print(json.load(sys.stdin)["user"])')
    info "Slack: bot identity = $USER"
  else
    warn "Slack: auth.test failed ($SLACK)"
  fi
else
  warn "Slack: SLACK_BOT_TOKEN not in env (~/.hermes/.env missing?)"
fi

# 5. Cron job count
N=$(sb_exec /usr/local/bin/hermes cron list 2>/dev/null | grep -cE 'active|paused' || true)
if [ "$N" -gt 0 ]; then info "Cron: $N job(s) scheduled"; else warn "Cron: 0 jobs (run bash ops/apply-cron.sh)"; fi

# 6. Bridges
B=$(ss -tlnp 2>/dev/null | grep -c ':8000' || true)
if [ "$B" -ge 2 ]; then info "vLLM bridges: $B listeners on :8000"; else warn "vLLM bridges: only $B listener(s) on :8000 — check systemctl --user status gandalf-vllm-bridge*"; fi

note "Use 'nemohermes gandalf doctor' for a deeper diagnostic."
