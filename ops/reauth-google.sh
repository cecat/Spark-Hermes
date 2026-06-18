#!/usr/bin/env bash
# Re-authorize Google for Gandalf via gog, then install the new token.
# Use when the Google token is revoked, expired, or you want to add/remove scopes.
#
# Reads defaults from ~/.hermes/config.yaml (google.agent_account, google.client_secret_host_path).
# Override at the CLI to use a different account or scope list.
#
# Prerequisites:
#   - gog CLI installed
#   - ~/.config/gogcli/credentials-gandalf.json + .gog_pw + config.json present
#     (one-time setup from bringup/30-google-oauth.md)
#
# Usage:
#   bash reauth-google.sh                                       # defaults from config.yaml
#   bash reauth-google.sh you@gmail.com                         # different email
#   bash reauth-google.sh you@gmail.com "gmail.send,gmail,drive"  # different scope list
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
require_hermes_config

EMAIL="${1:-$(hermes_cfg google.agent_account)}"
SERVICES="${2:-gmail,contacts,drive,sheets,docs,calendar}"
# Expand ~/ in the config-supplied path
CS_PATH=$(hermes_cfg google.client_secret_host_path | sed "s|^~|$HOME|")
CLIENT_SECRET="${CLIENT_SECRET:-$CS_PATH}"
TOKEN_HOST_PATH=$(hermes_cfg google.token_host_path | sed "s|^~|$HOME|")

[ -f "$CLIENT_SECRET" ] || fail "Missing client_secret.json at $CLIENT_SECRET (override with CLIENT_SECRET=...)"
[ -f ~/.config/gogcli/.gog_pw ] || fail "Missing ~/.config/gogcli/.gog_pw — see bringup/30-google-oauth.md"
[ -f ~/.config/gogcli/credentials-gandalf.json ] || fail "Missing ~/.config/gogcli/credentials-gandalf.json — see bringup/30-google-oauth.md"

note "Account: $EMAIL"
note "Services: $SERVICES"
note "Client secret: $CLIENT_SECRET"

note "Running gog auth add (browser dance — paste the redirect URL back at the prompt)..."
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog auth add "$EMAIL" --client gandalf --services "$SERVICES" --manual --force-consent

note "Exporting refresh token..."
TMP_EXPORT=$(mktemp)
rm -f "$TMP_EXPORT"   # gog auth tokens export refuses existing files
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog auth tokens export "$EMAIL" --client gandalf --out "$TMP_EXPORT" >/dev/null

note "Building Hermes-format google_token.json..."
TMP_TOKEN=$(mktemp)
python3 - "$TMP_EXPORT" "$CLIENT_SECRET" "$TMP_TOKEN" <<'PYEOF'
import json, sys, os
gog_path, cs_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
gog = json.load(open(gog_path))
cs = json.load(open(cs_path))
inner = cs.get('installed') or cs.get('web') or cs
token = {
  "type": "authorized_user",
  "client_id": inner['client_id'],
  "client_secret": inner['client_secret'],
  "refresh_token": gog['refresh_token'],
  "scopes": gog['scopes'],
  "token_uri": "https://oauth2.googleapis.com/token",
}
with open(out_path, 'w') as f: json.dump(token, f, indent=2)
os.chmod(out_path, 0o600)
PYEOF

note "Uploading token + client secret into sandbox..."
openshell sandbox upload gandalf "$TMP_TOKEN" /sandbox/.hermes/google_token.json >/dev/null
openshell sandbox upload gandalf "$CLIENT_SECRET" /sandbox/.hermes/google_client_secret.json >/dev/null

# Keep a host backup of the new token (per google.token_host_path in config.yaml)
cp "$TMP_TOKEN" "$TOKEN_HOST_PATH"
chmod 600 "$TOKEN_HOST_PATH"

# Clean up temp files
rm -f "$TMP_EXPORT" "$TMP_TOKEN"

note "Verifying..."
sb_exec /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/setup.py --check 2>&1 | head -10
info "Done."
