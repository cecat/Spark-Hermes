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
