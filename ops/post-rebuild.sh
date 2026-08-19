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
# `/hermes sethome` writes to ~/.hermes/.env — has to get in somehow.
#
# HOW THIS WORKS DEPENDS ON THE NEMOCLAW VERSION — see the guard check below.
#
# On v0.0.55 (no guard): we edit .env directly and hand-write the two-line
# integrity hash file. This is what the running deployment does today.
#
# From ~v0.0.110 (guard present): /etc/nemoclaw/hermes.config-hash is owned by
# hermes-runtime-config-guard.py, which seals config.yaml, .env and the hash
# together and tracks a restart seal. Hand-writing the hash produces a file
# that does not carry the seal state, so it is no longer a valid update.
# The guard's own `refresh-hashes` action cannot substitute: it is a *startup*
# action, restricted to the Hermes PID 1 transaction, and refuses to run from
# an ordinary docker exec ("restricted to the Hermes PID 1 startup transaction").
#
# On a guarded runtime these keys have sanctioned homes instead, and this
# manual sync should be retired rather than ported:
#   TAVILY_API_KEY  -> `nemohermes credentials add tavily-search --type tavily
#                       --credential TAVILY_API_KEY`. Tavily is a first-class
#                       Hermes web-search provider there and carries its own
#                       egress preset. The value stays in the gateway store
#                       rather than as plaintext in the sandbox.
#   *_HOME_CHANNEL  -> preserved automatically across rebuild by
#                       src/lib/state/preserved-env (patterns *_HOME_CHANNEL,
#                       *_HOME_CHANNEL_NAME, *_HOME_CHANNEL_THREAD_ID). The
#                       belt-and-suspenders copy is no longer needed.
#
# Add new entries to EXTRA_ENV_KEYS as the deployment grows.
HERMES_CONFIG_GUARD=/usr/local/lib/nemoclaw/hermes-runtime-config-guard.py

EXTRA_ENV_KEYS=(
  TAVILY_API_KEY                   # web search/extract/crawl via api.tavily.com
  SLACK_HOME_CHANNEL               # belt-and-suspenders: persist /hermes sethome across rebuilds
  TELEGRAM_HOME_CHANNEL            # same, for the Telegram adapter (also written by /sethome)
)

echo ""
echo "=== syncing extra env vars into sandbox .env ==="
if docker exec "$CONTAINER" test -f "$HERMES_CONFIG_GUARD" 2>/dev/null; then
  # Guarded runtime. Do NOT edit .env or the hash file by hand.
  warn "NemoClaw config guard present — skipping manual .env sync"
  echo "    /etc/nemoclaw/hermes.config-hash is guard-owned; hand-writing it would"
  echo "    desynchronise the restart seal and can stop the gateway starting."
  echo "    Migrate these keys to their sanctioned homes:"
  for KEY in "${EXTRA_ENV_KEYS[@]}"; do
    if docker exec "$CONTAINER" grep -q "^${KEY}=" /sandbox/.hermes/.env 2>/dev/null; then
      info "  ${KEY}: already present in sandbox .env"
    else
      case "$KEY" in
        TAVILY_API_KEY)
          warn "  ${KEY}: MISSING — run: nemohermes credentials add tavily-search --type tavily --credential TAVILY_API_KEY" ;;
        *_HOME_CHANNEL)
          warn "  ${KEY}: MISSING — expected to be preserved automatically; re-run '/hermes sethome' if web search or routing misbehaves" ;;
        *)
          warn "  ${KEY}: MISSING — no sanctioned home identified; investigate before relying on it" ;;
      esac
    fi
  done
else
  # Unguarded runtime (v0.0.55). Original behaviour.
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

# ── 5. Agent identity + procedures ─────────────────────────────────────
# A rebuild wipes the sandbox filesystem, so SOUL.md and the skills tree have
# to be re-pushed from the repo. Without this the agent comes back with the
# stock Hermes persona and none of its runbooks — it looks alive but isn't
# Gandalf. (Added 2026-07-28; previously neither was restored here.)
echo ""
echo "=== restoring SOUL.md from gandalf/soul/ ==="
bash "$REPO/ops/apply-soul.sh" 2>&1 | tail -5

echo ""
echo "=== restoring skills from gandalf/skills/ ==="
bash "$REPO/ops/apply-skills.sh" 2>&1 | tail -5

# ── 5b. FALDA memory provider (Phase 5c) ───────────────────────────────
# A rebuild wipes both the plugin (overlay) and memory.provider (config.yaml),
# so re-push the plugin AND re-activate it — otherwise Gandalf comes back with
# no external memory even though the tap keeps feeding FALDA. The active
# experiment condition lives in the versioned condition.yaml, which is restored
# with the plugin, so re-activating restores the pre-rebuild functional state.
echo ""
echo "=== restoring FALDA memory provider from gandalf/plugins/falda/ ==="
bash "$REPO/ops/apply-memory-provider.sh" --activate 2>&1 | tail -6

# ── 5c. Sibline sandbox bridge (Phase 8b) ──────────────────────────────
# A rebuild wipes the overlay /sandbox/.hermes/sibline/ tree AND changes the
# container id. The host-side broker + bridge survive (they're --user services),
# but the docker-exec shuttle caches the container name at launch, so it must be
# restarted to bind to the new container and recreate the sandbox-side tree.
# (The 5a FALDA egress preset is restored by apply-policies.sh in step 4 above;
# the sibline broker is loopback host-side and needs no sandbox egress.)
echo ""
echo "=== restarting Gandalf Sibline shuttle (rebinds to new container, recreates sandbox tree) ==="
if systemctl --user list-unit-files gandalf-sibline-shuttle.service >/dev/null 2>&1; then
  systemctl --user restart gandalf-sibline-shuttle.service 2>&1 | tail -2
  sleep 3
  if docker exec -u sandbox "$CONTAINER" sh -c 'test -d /sandbox/.hermes/sibline/outbox' 2>/dev/null; then
    info "sibline sandbox tree present (/sandbox/.hermes/sibline/)"
  else
    warn "sibline sandbox tree missing — check gandalf-sibline-shuttle.service"
  fi
else
  warn "gandalf-sibline-shuttle.service not installed — see spark-fabric services/sibline-bridge"
fi

# ── 6. Hermes cron jobs ────────────────────────────────────────────────
echo ""
echo "=== reconciling Hermes cron jobs against config.yaml ==="
bash "$REPO/ops/apply-cron.sh" --yes 2>&1 | tail -10

# ── 7. Smoke test ──────────────────────────────────────────────────────
echo ""
echo "=== smoke test: gmail search from sandbox ==="
if docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs "$CONTAINER" \
    /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/google_api.py gmail search "is:unread" --max 1 2>&1 | head -1 | grep -q '^\['; then
  info "gmail search returns JSON — post-rebuild restore complete"
else
  fail "gmail search FAILED after restore — check egress policy and token"
fi
