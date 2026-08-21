#!/usr/bin/env bash
# Health check for Gandalf. Same shape as bringup/60-smoke-tests.sh but quieter
# on success — designed to be run periodically.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
load_hermes_env

CONTAINER=$(gandalf_container)
note "Container: $CONTAINER"

# Gandalf lives on the port-8080 control plane, named 'nemoclaw'. cecat's
# tooling (ops/cecat-env.sh, the v0.0.108 CLI) flips the GLOBAL default gateway
# to nemoclaw-8090 as a side effect of onboard/exec, which used to make this
# script report "Sandbox phase: unknown" when Gandalf was perfectly healthy.
# Pin every query below to his gateway explicitly rather than trusting the
# ambient default. Also unset any inherited overrides from a sourced cecat env.
unset OPENSHELL_GATEWAY OPENSHELL_GATEWAY_ENDPOINT NEMOCLAW_GATEWAY_PORT 2>/dev/null || true
GW=(-g nemoclaw)
# Call Gandalf's 0.0.44 CLI by absolute path. ensure_path only PREPENDS
# ~/.local/bin when it is absent, so a sourced ops/cecat-env.sh leaves the
# 0.0.101 binary ahead of it on PATH and a bare `openshell` would talk to
# cecat's plane even with -g.
OSH="$HOME/.local/bin/openshell"

# 1. Sandbox phase (openshell colorizes output; strip ANSI before comparing)
PHASE=$("$OSH" "${GW[@]}" sandbox list 2>/dev/null | awk '/^gandalf/ {print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
[ "$PHASE" = "Ready" ] && info "Sandbox phase: Ready" || fail "Sandbox phase: ${PHASE:-unknown}"

# 2. Inference round-trip.
# The api_server gained an auth key (platforms.api_server.extra.key) with the
# phase0 work; without the bearer token every request is a 401, which this
# script used to report as a permanent false "Inference: FAIL".
API_KEY_FILE="$HOME/.config/falda/phase0-api-key.env"
AUTH_HDR="X-No-Auth: 1"
if [ -f "$API_KEY_FILE" ]; then
  K=$(sed -n 's/^API_SERVER_KEY=//p' "$API_KEY_FILE" | head -1)
  [ -n "$K" ] && AUTH_HDR="Authorization: Bearer $K"
fi
REPLY=$(curl -sS -m 30 -X POST http://127.0.0.1:8642/v1/chat/completions \
  -H "$AUTH_HDR" \
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
