#!/usr/bin/env bash
# inject-openshell-ca.sh
# Make Python TLS clients (httplib2 → google-api-python-client → Gmail/Sheets/Drive/Docs)
# trust the OpenShell sandbox TLS-inspection proxy.
#
# Background:
#   Outbound HTTPS in this sandbox is forced through http://10.200.0.1:3128, which
#   re-signs every server cert with `CN=OpenShell Sandbox CA, O=OpenShell`. The system
#   trust store + curl already trust this CA, but Python libraries that bundle their
#   own CA list (notably `certifi`, which `httplib2` uses) don't — so calls to
#   sheets.googleapis.com etc. fail with `self-signed certificate in certificate chain`.
#
# Fix: capture the proxy's root cert and append it to certifi's bundle (the file
#      `httplib2.CA_CERTS` resolves to). Idempotent — re-runs are safe.
#
# Run this once after any `pip install certifi` or sandbox rebuild.
set -euo pipefail

CERTIFI="${1:-/sandbox/.hermes/pylibs/certifi/cacert.pem}"
MARKER="OpenShell Sandbox CA"

if [ ! -f "$CERTIFI" ]; then
  echo "ERR: certifi bundle not found at $CERTIFI" >&2
  exit 1
fi

if grep -q "$MARKER" "$CERTIFI"; then
  echo "Already trusted ($MARKER present in $CERTIFI). No-op."
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Capture chain through the proxy (any HTTPS host works; sheets.googleapis.com is convenient)
openssl s_client -connect sheets.googleapis.com:443 -servername sheets.googleapis.com \
  -proxy 10.200.0.1:3128 -showcerts < /dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > "$TMP"

if [ ! -s "$TMP" ]; then
  echo "ERR: failed to capture proxy cert chain. Is the proxy reachable?" >&2
  exit 1
fi

# Take only the LAST cert in the chain — that's the root we want to trust
ROOT=$(awk '/BEGIN CERTIFICATE/{c++; certs[c]=""} {certs[c]=certs[c] $0 "\n"} END{printf "%s", certs[c]}' "$TMP")

cp "$CERTIFI" "${CERTIFI}.bak.$(date -u +%Y%m%dT%H%M%SZ)"

{
  echo ""
  echo "# OpenShell Sandbox CA — injected $(date -u +%Y-%m-%dT%H:%M:%SZ) by inject-openshell-ca.sh"
  echo "$ROOT"
} >> "$CERTIFI"

echo "OK: injected OpenShell root CA into $CERTIFI"
echo "Backup: ${CERTIFI}.bak.*"
