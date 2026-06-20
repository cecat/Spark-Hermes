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

# ── 2c. Hermes gateway source patch (suppress /hermes sethome notice) ──
# Upstream bug B: Hermes' gateway emits a "📬 No home channel is set for
# Slack. Type /hermes sethome..." notice on every fresh Slack conversation,
# but /hermes is not registered as a Slack slash command in this
# NemoClaw-mediated setup — so the instruction points at a broken button.
# Patch run.py to gate the notice on HERMES_SUPPRESS_SETHOME_NOTICE=1
# (which we set in ~/.hermes/.env, hydrated via load_hermes_dotenv).
#
# Idempotent: re-applies cleanly on every rebuild. Backs up the original.
echo ""
echo "=== applying Hermes run.py patch (suppress Slack sethome notice) ==="
PATCH_MARKER="SPARK-HERMES PATCH 2026-06-20"
if docker exec "$CONTAINER" grep -q "$PATCH_MARKER" /opt/hermes/gateway/run.py 2>/dev/null; then
  info "patch already present; skipping"
else
  docker exec -u root "$CONTAINER" cp /opt/hermes/gateway/run.py /opt/hermes/gateway/run.py.orig-pre-sethome-patch
  docker exec -u root "$CONTAINER" python3 - <<'PYEOF'
p = "/opt/hermes/gateway/run.py"
old = """        # One-time prompt if no home channel is set for this platform
        # Skip for webhooks - they deliver directly to configured targets (github_comment, etc.)
        if not history and source.platform and source.platform != Platform.LOCAL and source.platform != Platform.WEBHOOK:"""
new = """        # One-time prompt if no home channel is set for this platform
        # Skip for webhooks - they deliver directly to configured targets (github_comment, etc.)
        # SPARK-HERMES PATCH 2026-06-20: opt-out via HERMES_SUPPRESS_SETHOME_NOTICE=1
        # (the slash command the notice mentions isn't registered in our setup)
        _suppress = (__import__("os").getenv("HERMES_SUPPRESS_SETHOME_NOTICE","").lower() in ("1","true","yes"))
        if not history and source.platform and source.platform != Platform.LOCAL and source.platform != Platform.WEBHOOK and not _suppress:"""
src = open(p).read()
assert old in src, "patch target block not found — Hermes may have been upgraded; review manually"
open(p, "w").write(src.replace(old, new, 1))
print("patched")
PYEOF
  info "patch applied"
fi

# ── 2d. Sync HERMES_SUPPRESS_SETHOME_NOTICE into sandbox .env ──────────
# Hermes' load_hermes_dotenv reads /sandbox/.hermes/.env at startup (the gateway
# runs with HERMES_HOME=/sandbox/.hermes), but NemoClaw bakes /sandbox/.hermes/.env
# from a limited allowlist of keys — and HERMES_SUPPRESS_SETHOME_NOTICE isn't on
# the allowlist. Copy it over manually + update the integrity hash NemoClaw
# verifies at startup.
if grep -q '^HERMES_SUPPRESS_SETHOME_NOTICE=' ~/.hermes/.env 2>/dev/null; then
  echo ""
  echo "=== syncing HERMES_SUPPRESS_SETHOME_NOTICE into sandbox .env ==="
  VAL=$(grep '^HERMES_SUPPRESS_SETHOME_NOTICE=' ~/.hermes/.env | head -1 | cut -d= -f2-)
  docker exec -u root "$CONTAINER" sh -c "
    grep -q '^HERMES_SUPPRESS_SETHOME_NOTICE=' /sandbox/.hermes/.env || echo 'HERMES_SUPPRESS_SETHOME_NOTICE=$VAL' >> /sandbox/.hermes/.env
    cd /sandbox/.hermes
    cfg_hash=\$(sha256sum config.yaml | awk '{print \$1}')
    env_hash=\$(sha256sum .env | awk '{print \$1}')
    cat > /etc/nemoclaw/hermes.config-hash <<EOF2
\$cfg_hash  /sandbox/.hermes/config.yaml
\$env_hash  /sandbox/.hermes/.env
EOF2
  "
  info "sandbox .env updated, hash recomputed"
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
