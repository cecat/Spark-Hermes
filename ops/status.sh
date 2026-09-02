#!/usr/bin/env bash
# Health check for Gandalf. Same shape as bringup/60-smoke-tests.sh but quieter
# on success — designed to be run periodically.
#
# ⚠ THIS SCRIPT IS NOT READ-ONLY. Check 2 POSTs a real chat completion into the
#   LIVE agent on :8642 (an actual inference request and a real turn, billed and
#   logged like any other). Despite the name, do not treat `status.sh` as a safe
#   passive probe: do not run it in a tight loop, and do not run it while
#   diagnosing agent-side state you do not want perturbed. The POST is load
#   bearing as an end-to-end inference check — other things may depend on it —
#   so it stays.
#
# ⚠ SCOPE OF WHAT THIS PROVES. Every check below runs from the HOST. Checks that
#   reach into the sandbox do so via sb_exec; the Slack check (4) does NOT — it
#   only validates a token from the host and CANNOT see whether the in-sandbox
#   Slack adapter is actually connected and delivering. See the comment at check
#   4. A green run of this script is not evidence that Gandalf can receive or
#   answer a Slack message.
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

# 4. Slack TOKEN VALIDITY ONLY — this is NOT a Slack health check.
#
# This curl runs on the HOST and asks Slack "is this token valid?". That is all
# it can answer. It does NOT prove:
#   - that the in-sandbox Slack adapter process is running
#   - that its socket-mode WebSocket is connected
#   - that an inbound DM or app_mention would be received
#   - that a reply would be delivered
# The adapter lives inside the sandbox and long-polls Slack itself; the host has
# no visibility into it. A host probe of an in-sandbox capability is exactly the
# shape that let an 11-day in-sandbox egress outage pass unnoticed while a
# host-side check stayed green — so this check is deliberately labelled for what
# it is, and its output says "token" not "Slack".
#
# Verifying the adapter for real requires the layer that owns it: a HUMAN typing
# a message and observing `Inbound app_mention` → `delivered reply` in
# `nemohermes gandalf logs`. That cannot be scripted — Slack stamps any
# app-token-authored message with a bot_id, and the adapter drops bot-authored
# messages, so a scripted "test" would pass without exercising the real path.
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  SLACK=$(curl -sS -m 10 -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test 2>/dev/null)
  if echo "$SLACK" | grep -q '"ok":true'; then
    USER=$(echo "$SLACK" | python3 -c 'import json,sys;print(json.load(sys.stdin)["user"])')
    info "Slack token: VALID (bot identity = $USER) — token only; adapter connectivity NOT checked"
  else
    warn "Slack token: auth.test FAILED ($SLACK)"
  fi
else
  warn "Slack token: SLACK_BOT_TOKEN not in env (~/.hermes/.env missing?)"
fi
note "Slack adapter health is NOT verified by this script — confirm by having a human DM the bot and watching 'nemohermes gandalf logs' for inbound→reply."

# 5. Cron job count
N=$(sb_exec /usr/local/bin/hermes cron list 2>/dev/null | grep -cE 'active|paused' || true)
if [ "$N" -gt 0 ]; then info "Cron: $N job(s) scheduled"; else warn "Cron: 0 jobs (run bash ops/apply-cron.sh)"; fi

# 6. Bridges
B=$(ss -tlnp 2>/dev/null | grep -c ':8000' || true)
if [ "$B" -ge 2 ]; then info "vLLM bridges: $B listeners on :8000"; else warn "vLLM bridges: only $B listener(s) on :8000 — check systemctl --user status gandalf-vllm-bridge*"; fi

note "Use 'nemohermes gandalf doctor' for a deeper diagnostic."
