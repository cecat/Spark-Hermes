#!/usr/bin/env bash
# Prove an agent's Google access actually works, from inside its OpenShell
# sandbox, with a READ-ONLY call.
#
#   bash ops/verify-google.sh            # both agents
#   bash ops/verify-google.sh luoji      # one
#
# READ ONLY. Sends no email, creates nothing, deletes nothing, modifies nothing.
# Exercises the whole chain at once: OS trust store (CA), credentials, the L7
# egress preset, and — for luoji — the gog wrapper and keyring.
#
# WHY THIS EXISTS: credentials being present is NOT proof. That is the
# log-timestamp error (see patterns/dispatching-workers.md). A capability is YES
# only on an observed request-and-response.
set -u

AGENTS="${1:-cecat luoji}"
RC=0

for AGENT in $AGENTS; do
  echo "════════════════════════════════════════════"
  echo "  $AGENT"
  echo "════════════════════════════════════════════"

  CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
  if [ -z "$CON" ]; then
    echo "  NO RUNNING SANDBOX"; RC=1; continue
  fi

  echo "--- 1. proxy CA in the OS trust store? ---"
  docker exec -u sandbox -i "$CON" sh <<'SH'
b=/etc/ssl/certs/ca-certificates.crt
if [ -f "$b" ]; then
  echo "  system bundle certs: $(grep -c 'BEGIN CERTIFICATE' "$b")"
else
  echo "  MISSING $b"
fi
if [ -f /usr/local/share/ca-certificates/openshell-proxy.crt ]; then
  echo "  proxy CA installed : yes"
else
  echo "  proxy CA installed : NO  <-- Go and curl will fail with unknown-authority"
fi
SH

  if [ "$AGENT" = "luoji" ]; then
    echo "--- 2. gog present and wired? ---"
    docker exec -u sandbox -i "$CON" sh <<'SH'
command -v gog >/dev/null && echo "  gog on PATH    : $(command -v gog)" || echo "  gog on PATH    : NOT FOUND"
[ -x /usr/local/lib/gog/gog ] && echo "  real binary    : present" || echo "  real binary    : MISSING"
[ -f /sandbox/.config/gogcli/.gog_pw ] && echo "  keyring pw     : present" || echo "  keyring pw     : MISSING"
echo "  keyring items  : $(ls /sandbox/.config/gogcli/keyring 2>/dev/null | wc -l)"
SH

    echo "--- 3. READ-ONLY Google call: gog contacts search ---"
    docker exec -u sandbox -i "$CON" sh <<'SH' 2>&1 | sed 's/^/  /'
cd /sandbox
timeout 90 gog contacts search --query a --limit 2 2>&1 | head -20
echo "---exit:$?---"
SH

  else
    echo "--- 2. gsuite-mcp credentials present? ---"
    docker exec -u sandbox -i "$CON" sh <<'SH'
[ -f /sandbox/.local/share/gsuite-mcp/token.json ] && echo "  token.json       : present" || echo "  token.json       : MISSING"
[ -f /sandbox/.config/gsuite-mcp/credentials.json ] && echo "  credentials.json : present" || echo "  credentials.json : MISSING"
command -v curl >/dev/null && echo "  curl             : $(command -v curl)" || echo "  curl             : NOT FOUND"
SH

    echo "--- 3. READ-ONLY Google call: Gmail profile via her own script ---"
    docker exec -u sandbox -i "$CON" sh <<'SH' 2>&1 | sed 's/^/  /'
cd /sandbox
S=""
for c in /sandbox/.openclaw/workspace/scripts/gmail-api.py /scripts/gmail-api.py /sandbox/scripts/gmail-api.py; do
  [ -f "$c" ] && S="$c" && break
done
if [ -z "$S" ]; then
  echo "gmail-api.py NOT FOUND in sandbox (see punchlist P-6)"
  echo "falling back to a raw token-refresh + profile read is NOT attempted here."
  echo "---exit:127---"
else
  echo "using $S"
  timeout 90 python3 "$S" profile 2>&1 | head -20
  echo "---exit:$?---"
fi
SH
  fi
  echo
done

echo "════════════════════════════════════════════"
echo "HOW TO READ THIS"
echo "════════════════════════════════════════════"
echo "  A real response (contact names, an email address, a profile blob) = YES."
echo "  'unknown authority' / 'certificate signed by unknown' = CA not installed."
echo "  'DENIED' in the agent's log at the same moment  = egress preset gap."
echo "  'No such file' for gmail-api.py                 = punchlist P-6, not a"
echo "                                                    Google-access failure."
exit $RC
