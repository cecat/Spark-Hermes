#!/usr/bin/env bash
# Install the NextDNS daemon on the Spark host and point the system resolver
# at it. After this runs, every process on Spark (host shells, Gandalf sandbox,
# OpenClaw agent containers, anything else) does DNS through NextDNS profile
# "Spark" (id=YOUR_NEXTDNS_PROFILE_ID) — meaning the categories/blocklists configured in the
# NextDNS dashboard take effect for all outbound name lookups.
#
# Why DNS-level filtering at all: gives us category-based blocking (malware,
# phishing, porn, piracy, etc.) without having to maintain allowlists by hand.
# Composes with OpenShell's L7 proxy policy — blocked domains never resolve,
# so they never reach the proxy. Defense in depth.
#
# What this script does:
#   1. Add the NextDNS apt repo and signing key.
#   2. apt install nextdns.
#   3. Run `nextdns install -config YOUR_NEXTDNS_PROFILE_ID -report-client-info -auto-activate`
#      which installs the daemon, points systemd-resolved at it (127.0.0.1:53),
#      and starts it. -report-client-info makes the dashboard's Analytics tab
#      show per-source-IP breakdown so you can tell Gandalf's queries from
#      yours. -auto-activate flips the system resolver over for you.
#   4. Verify by resolving a known-clean name and a known-blocked name.
#
# Reversible: `sudo nextdns uninstall` puts the resolver back the way it was.
#
# Non-destructive: does NOT touch any container, agent, OpenShell policy, or
# user data. Pure host-network plumbing.
set -eu

# Set these before running. Get the profile id from the NextDNS dashboard:
# Setup tab → Endpoints box → "ID" row (a short hex string like "abc123").
PROFILE_ID="${NEXTDNS_PROFILE_ID:-YOUR_NEXTDNS_PROFILE_ID}"
PROFILE_NAME="${NEXTDNS_PROFILE_NAME:-Spark}"

if [ "$PROFILE_ID" = "YOUR_NEXTDNS_PROFILE_ID" ]; then
  echo "ERROR: set NEXTDNS_PROFILE_ID first." >&2
  echo "  export NEXTDNS_PROFILE_ID=abc123    # from your dashboard's Setup tab" >&2
  echo "  bash $(basename "$0")" >&2
  exit 2
fi

note()  { printf '\033[0;36m[i]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[✓]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail()  { printf '\033[0;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "Run as your normal user; the script will sudo where needed."

# 1. Install the package using NextDNS's official one-line installer.
#    This handles repo signing key + apt source + package install across distros.
#    Source: https://github.com/nextdns/nextdns/wiki/Debian-Based-Distribution
if ! command -v nextdns >/dev/null 2>&1; then
  note "Running NextDNS official installer (sets up repo + installs package)..."
  sh -c "$(curl -fsSL https://nextdns.io/install)"
  ok "Installed: $(nextdns version 2>/dev/null | head -1)"
else
  ok "nextdns already installed: $(nextdns version 2>/dev/null | head -1)"
fi

# 2. Install + activate the daemon for profile 'Spark' (id $PROFILE_ID)
#    -report-client-info: dashboard sees source IPs (so you can tell containers apart)
#    -auto-activate: flips system resolver to 127.0.0.1 automatically
#    -log-queries=false: keep host disk quiet; the NextDNS dashboard has Logs anyway
note "Installing/configuring daemon for profile '$PROFILE_NAME' (id=$PROFILE_ID)..."
sudo nextdns install \
  -config "$PROFILE_ID" \
  -report-client-info \
  -auto-activate \
  -log-queries=false 2>&1 | sed 's/^/    /'

sudo nextdns start 2>&1 | sed 's/^/    /' || true
sleep 1
nextdns status || warn "nextdns status returned non-zero — check 'sudo journalctl -u nextdns -n 50'"

# 3. Verify: clean lookups succeed; known-bad lookups return empty.
#    We hit the daemon directly via `dig @127.0.0.1` so we measure NextDNS,
#    not whatever the system resolver happens to be doing.
echo ""
note "Smoke test 1/3: daemon resolves a clean host (example.com)..."
if [ -n "$(dig +short +time=3 +tries=1 example.com @127.0.0.1 2>/dev/null)" ]; then
  ok "example.com resolves through NextDNS"
else
  fail "example.com did NOT resolve via 127.0.0.1 — daemon may not be connected. Check 'sudo journalctl -u nextdns -n 30'."
fi

note "Smoke test 2/3: malware test host blocked..."
# bambenekconsulting.com is a real malware-research domain that NextDNS's
# Threat Intelligence Feeds blocklist returns NXDOMAIN for.
if [ -z "$(dig +short +time=3 +tries=1 malware.bambenekconsulting.com @127.0.0.1 2>/dev/null)" ]; then
  ok "malware.bambenekconsulting.com BLOCKED (Security categories active)"
else
  warn "malware.bambenekconsulting.com resolved — Security category may be off. Check NextDNS dashboard → Security tab."
fi

note "Smoke test 3/3: OS resolver is using NextDNS (not bypassing)..."
# resolvectl status will name 127.0.0.1 if -auto-activate did its job.
if resolvectl status 2>/dev/null | grep -q '127.0.0.1'; then
  ok "systemd-resolved is pointing at 127.0.0.1 (NextDNS)"
else
  warn "systemd-resolved is NOT pointing at NextDNS. Run 'sudo nextdns activate' to force."
fi

echo ""
ok "Done. The Spark host now uses NextDNS profile '$PROFILE_NAME' for all DNS."
note "What this affects automatically:"
note "  • Host shells, brew installs, curl/wget, browsers if any"
note "  • Every Docker container that uses the host resolver — including Gandalf, OpenClaw agents"
note "  • The OpenShell L7 proxy's upstream lookups (so unauthorized hosts won't resolve before the proxy even sees them)"
echo ""
note "To check what's happening live:"
note "  • Dashboard → Logs tab (most recent queries by source IP, ALLOW/BLOCK status)"
note "  • Local: sudo journalctl -u nextdns -f"
echo ""
note "To revert if anything breaks:"
note "  sudo nextdns uninstall      # restores the previous resolver config"
