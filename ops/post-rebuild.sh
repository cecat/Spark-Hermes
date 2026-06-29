#!/usr/bin/env bash
# Restore the post-bringup state that `nemohermes gandalf rebuild` silently
# drops. Run this AFTER any rebuild, OR as a step inside ops/rebuild.sh.
#
# What rebuild drops, and what we restore here:
#   1. /sandbox/.hermes/pylibs/  — Google API Python deps (google-api-python-client etc.)
#                                  Required by the google-workspace skill scripts.
#   2. /sandbox/.hermes/google_token.json + google_client_secret.json
#                                — OAuth state. Without them the skill says "not authenticated".
#   3. Custom OpenShell policy presets (google-workspace-egress, managed-inference-widen)
#                                — Sandbox starts with only the built-in presets; ours
#                                  have to be re-applied via `nemohermes gandalf policy-add`.
#   4. The cron job set in ~/.hermes/config.yaml
#                                — rebuild preserves jobs by ID, but apply-cron is idempotent
#                                  and reconciles any drift.
#
# Idempotent: re-running with everything already in place is a no-op.

set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
require_hermes_config

REPO=$(repo_root)
CONTAINER=$(gandalf_container)
AGENT=$(hermes_cfg agent.name)

# ── 1. Google API Python deps ──────────────────────────────────────────
echo "=== restoring Google API Python deps ==="
if docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs "$CONTAINER" \
    /opt/hermes/.venv/bin/python -c 'import googleapiclient' 2>/dev/null; then
  info "googleapiclient already importable; skipping pip install"
else
  warn "googleapiclient missing — installing into /sandbox/.hermes/pylibs/"
  docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e UV_CACHE_DIR=/tmp/uv-cache "$CONTAINER" \
    sh -c 'uv pip install --target /sandbox/.hermes/pylibs --python /opt/hermes/.venv/bin/python google-api-python-client google-auth-oauthlib google-auth-httplib2 2>&1 | tail -3'
  info "installed"
fi

# ── 1b. Inject OpenShell CA into certifi bundle ────────────────────────
# httplib2 (used by google-api-python-client) trusts only certifi's bundled
# Mozilla CA list, which doesn't include the OpenShell sandbox's TLS-
# inspection proxy root. Without this, Python calls to googleapis.com fail
# with "self-signed certificate in certificate chain" — even though our
# env-var path (HTTPLIB2_CA_CERTS=/etc/openshell-tls/ca-bundle.pem) covers
# every cron script, interactive tool-use sessions inside the gateway
# don't always pick up that env. Belt and suspenders: also patch the bundle
# itself so a bare Python invocation works.
#
# The script is idempotent (greps for "OpenShell Sandbox CA" marker before
# appending). Source of truth: sandbox-scripts/inject-openshell-ca.sh.
echo ""
echo "=== injecting OpenShell CA into certifi bundle ==="
INJECT_SH="$REPO/sandbox-scripts/inject-openshell-ca.sh"
if [ -f "$INJECT_SH" ]; then
  # Upload (it's also uploaded in step 3 below but we need it now, before that runs)
  docker exec "$CONTAINER" mkdir -p /sandbox/.hermes/scripts
  docker cp "$INJECT_SH" "$CONTAINER:/sandbox/.hermes/scripts/inject-openshell-ca.sh"
  docker exec "$CONTAINER" chown sandbox:sandbox /sandbox/.hermes/scripts/inject-openshell-ca.sh
  docker exec "$CONTAINER" chmod +x /sandbox/.hermes/scripts/inject-openshell-ca.sh
  docker exec -u sandbox "$CONTAINER" bash /sandbox/.hermes/scripts/inject-openshell-ca.sh 2>&1 | sed 's/^/    /'
else
  warn "inject-openshell-ca.sh not found in repo; skipping certifi patch"
fi

# ── 2. Google OAuth token + client secret ──────────────────────────────
echo ""
echo "=== restoring Google OAuth credentials ==="
TOKEN_HOST=$(hermes_cfg google.token_host_path | sed "s|^~|$HOME|")
CS_HOST=$(hermes_cfg google.client_secret_host_path | sed "s|^~|$HOME|")

if docker exec "$CONTAINER" test -f /sandbox/.hermes/google_token.json 2>/dev/null; then
  info "google_token.json already in sandbox"
else
  [ -f "$TOKEN_HOST" ] || fail "Host backup missing at $TOKEN_HOST — re-auth via ops/reauth-google-custom-scopes.py first"
  warn "uploading google_token.json from $TOKEN_HOST"
  openshell sandbox upload "$AGENT" "$TOKEN_HOST" /sandbox/.hermes/google_token.json >/dev/null
  info "uploaded"
fi

if docker exec "$CONTAINER" test -f /sandbox/.hermes/google_client_secret.json 2>/dev/null; then
  info "google_client_secret.json already in sandbox"
else
  [ -f "$CS_HOST" ] || fail "Host backup missing at $CS_HOST"
  warn "uploading google_client_secret.json from $CS_HOST"
  openshell sandbox upload "$AGENT" "$CS_HOST" /sandbox/.hermes/google_client_secret.json >/dev/null
  info "uploaded"
fi

# Verify the auth works end-to-end
echo ""
echo "=== verifying Google auth ==="
if docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs "$CONTAINER" \
    /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/setup.py --check 2>&1 | grep -q AUTHENTICATED; then
  info "google-workspace: AUTHENTICATED"
else
  warn "google-workspace: setup.py --check did NOT report AUTHENTICATED. Run ops/reauth-google-custom-scopes.py to refresh."
fi

# ── 2b. agent-identity.json (operator + agent emails) ─────────────────
# sandbox-scripts/outbox-send.py reads this to build its recipient
# allowlist. Sourced from ~/.hermes/config.yaml so the repo doesn't have
# to bake in deployment-specific addresses.
echo ""
echo "=== writing /sandbox/.hermes/agent-identity.json ==="
AGENT_EMAIL_VAL=$(hermes_cfg google.agent_account)
OP_PRIMARY=$(hermes_cfg operator.primary_email)
OP_WORK=$(hermes_cfg operator.work_email)
IDENTITY_JSON=$(python3 -c "
import json
print(json.dumps({
  'agent_email': '$AGENT_EMAIL_VAL',
  'operator_emails': [e for e in ['$OP_PRIMARY', '$OP_WORK'] if e]
}, indent=2))
")
docker exec -u sandbox -i "$CONTAINER" sh -c 'cat > /sandbox/.hermes/agent-identity.json' <<< "$IDENTITY_JSON"
info "agent-identity.json written (agent=$AGENT_EMAIL_VAL)"

# ── 2c. (removed) Slack sethome notice suppression ─────────────────────
# The previous version of this script patched /opt/hermes/gateway/run.py to
# gate the "📬 No home channel is set for Slack. Type /hermes sethome..."
# notice behind HERMES_SUPPRESS_SETHOME_NOTICE=1. That was treating the
# symptom, not the cause: /hermes wasn't reaching the gateway because the
# Slack app manifest never declared the slash command. The patch also
# didn't survive container restarts (the writable layer is wiped), so it
# was an in-effect no-op anyway.
#
# Fix is in bringup/20-slack-app/manifest.{yaml,json}: declare /hermes,
# reinstall the app to the workspace. Once /hermes works, the user can
# `/hermes sethome` once and the notice stops firing — no patch needed.
#
# Removed 2026-06-29. See bringup/20-slack-app/README.md "Day 2" section.

# ── 2d. Sync extra env vars into sandbox .env ──────────────────────────
# Hermes' load_hermes_dotenv reads /sandbox/.hermes/.env at startup (the gateway
# runs with HERMES_HOME=/sandbox/.hermes), but NemoClaw bakes that file from a
# limited allowlist of keys. Anything outside that allowlist that we need —
# third-party API keys, plus the platform HOME_CHANNEL env vars that
# `/hermes sethome` writes to ~/.hermes/.env — must be copied in manually
# and the NemoClaw integrity hash updated.
#
# Add new entries to EXTRA_ENV_KEYS as the deployment grows.
EXTRA_ENV_KEYS=(
  TAVILY_API_KEY                   # web search/extract/crawl via api.tavily.com
  SLACK_HOME_CHANNEL               # belt-and-suspenders: persist /hermes sethome across rebuilds
  TELEGRAM_HOME_CHANNEL            # same, for the Telegram adapter (also written by /sethome)
)
SYNCED_ANY=0
for KEY in "${EXTRA_ENV_KEYS[@]}"; do
  if grep -q "^${KEY}=" ~/.hermes/.env 2>/dev/null; then
    VAL=$(grep "^${KEY}=" ~/.hermes/.env | head -1 | cut -d= -f2-)
    # Add or replace in sandbox .env
    docker exec -u root "$CONTAINER" sh -c "
      if grep -q '^${KEY}=' /sandbox/.hermes/.env; then
        sed -i 's|^${KEY}=.*|${KEY}=${VAL}|' /sandbox/.hermes/.env
      else
        echo '${KEY}=${VAL}' >> /sandbox/.hermes/.env
      fi
    "
    info "synced ${KEY} into sandbox .env"
    SYNCED_ANY=1
  fi
done
if [ "$SYNCED_ANY" -eq 1 ]; then
  echo ""
  echo "=== recomputing NemoClaw integrity hash after .env edits ==="
  docker exec -u root "$CONTAINER" sh -c '
    cd /sandbox/.hermes
    cfg_hash=$(sha256sum config.yaml | awk "{print \$1}")
    env_hash=$(sha256sum .env | awk "{print \$1}")
    cat > /etc/nemoclaw/hermes.config-hash <<EOF2
$cfg_hash  /sandbox/.hermes/config.yaml
$env_hash  /sandbox/.hermes/.env
EOF2
  '
  info "integrity hash updated"
fi

# ── 3. Sandbox-side scripts (Hermes no-agent cron jobs) ────────────────
echo ""
echo "=== restoring sandbox-side scripts to /sandbox/.hermes/scripts/ ==="
SCRIPT_DIR="$REPO/sandbox-scripts"
if [ -d "$SCRIPT_DIR" ]; then
  docker exec "$CONTAINER" mkdir -p /sandbox/.hermes/scripts
  for f in "$SCRIPT_DIR"/*; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    docker cp "$f" "$CONTAINER:/sandbox/.hermes/scripts/$bn"
    docker exec "$CONTAINER" chown sandbox:sandbox "/sandbox/.hermes/scripts/$bn"
    docker exec "$CONTAINER" chmod +x "/sandbox/.hermes/scripts/$bn"
    info "uploaded $bn"
  done
else
  warn "no sandbox-scripts/ dir in repo; skipping"
fi

# ── 4. Custom OpenShell policy presets ─────────────────────────────────
echo ""
echo "=== restoring custom OpenShell policy presets ==="
bash "$REPO/ops/apply-policies.sh" 2>&1 | tail -5

# ── 5. Hermes cron jobs ────────────────────────────────────────────────
echo ""
echo "=== reconciling Hermes cron jobs against config.yaml ==="
bash "$REPO/ops/apply-cron.sh" --yes 2>&1 | tail -10

# ── 6. Smoke test ──────────────────────────────────────────────────────
echo ""
echo "=== smoke test: gmail search from sandbox ==="
if docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs "$CONTAINER" \
    /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/google_api.py gmail search "is:unread" --max 1 2>&1 | head -1 | grep -q '^\['; then
  info "gmail search returns JSON — post-rebuild restore complete"
else
  fail "gmail search FAILED after restore — check egress policy and token"
fi
