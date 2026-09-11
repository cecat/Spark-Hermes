#!/usr/bin/env bash
# Inspect whether an agent's sandbox is READY to make Google calls.
# Pure filesystem inspection — makes NO network call of any kind.
#
#   bash ops/check-google-readiness.sh            # both
#   bash ops/check-google-readiness.sh luoji      # one
#
# This is the companion to ops/verify-google.sh, which performs the actual
# read-only API call. Readiness here is necessary but NOT sufficient: a green
# result from this script is exactly the "credentials are present so it must
# work" inference that has been wrong twice on this box. Prove it with a call.
set -u

AGENTS="${1:-cecat luoji}"

for AGENT in $AGENTS; do
  echo "════════════════════════════════════════════"
  echo "  $AGENT"
  echo "════════════════════════════════════════════"

  CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
  if [ -z "$CON" ]; then
    echo "  NO RUNNING SANDBOX"; continue
  fi

  echo "--- proxy CA in the OS trust store ---"
  docker exec -u sandbox -i "$CON" sh <<'SH'
b=/etc/ssl/certs/ca-certificates.crt
[ -f "$b" ] && echo "  system bundle certs : $(grep -c 'BEGIN CERTIFICATE' "$b")" \
            || echo "  system bundle       : MISSING $b"
[ -f /usr/local/share/ca-certificates/openshell-proxy.crt ] \
  && echo "  proxy CA installed  : YES" \
  || echo "  proxy CA installed  : NO  <-- curl and Go fail with unknown-authority"
[ -f /etc/openshell-tls/ca-bundle.pem ] \
  && echo "  source CA available : yes (/etc/openshell-tls/ca-bundle.pem)" \
  || echo "  source CA available : NO"
SH

  if [ "$AGENT" = "luoji" ]; then
    echo "--- gog toolchain ---"
    docker exec -u sandbox -i "$CON" sh <<'SH'
command -v gog >/dev/null && echo "  gog on PATH   : $(command -v gog)" || echo "  gog on PATH   : NOT FOUND"
[ -x /usr/local/lib/gog/gog ] && echo "  real binary   : present, executable" || echo "  real binary   : MISSING"
[ -f /sandbox/.config/gogcli/.gog_pw ] && echo "  keyring pw    : present ($(stat -c%a /sandbox/.config/gogcli/.gog_pw 2>/dev/null))" || echo "  keyring pw    : MISSING"
[ -f /sandbox/.config/gogcli/config.json ] && echo "  config.json   : present" || echo "  config.json   : MISSING"
echo "  keyring items : $(ls /sandbox/.config/gogcli/keyring 2>/dev/null | wc -l)"
echo "  cred files    : $(ls /sandbox/.config/gogcli/credentials*.json 2>/dev/null | wc -l)"
echo "  SSL_CERT_FILE : ${SSL_CERT_FILE:-(unset - correct; setting it would REPLACE system roots)}"
SH
  else
    echo "--- gsuite-mcp credentials ---"
    docker exec -u sandbox -i "$CON" sh <<'SH'
[ -f /sandbox/.local/share/gsuite-mcp/token.json ] \
  && echo "  token.json       : present ($(stat -c%a /sandbox/.local/share/gsuite-mcp/token.json))" \
  || echo "  token.json       : MISSING"
[ -f /sandbox/.config/gsuite-mcp/credentials.json ] \
  && echo "  credentials.json : present ($(stat -c%a /sandbox/.config/gsuite-mcp/credentials.json))" \
  || echo "  credentials.json : MISSING"
command -v curl >/dev/null && echo "  curl             : $(command -v curl)" || echo "  curl             : NOT FOUND"
echo "--- her scripts: are they reachable in the sandbox? (punchlist P-6) ---"
found=0
for c in /sandbox/.openclaw/workspace/scripts/gmail-api.py /scripts/gmail-api.py /sandbox/scripts/gmail-api.py; do
  [ -f "$c" ] && echo "  gmail-api.py     : $c" && found=1 && break
done
[ "$found" = 0 ] && echo "  gmail-api.py     : NOT FOUND — runbooks call /scripts/, which does not exist here"
SH
  fi
  echo
done

echo "════════════════════════════════════════════"
echo "  READY is not WORKING. Prove it with ops/verify-google.sh."
echo "════════════════════════════════════════════"
