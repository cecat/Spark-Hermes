#!/usr/bin/env bash
# Restore DNS for OpenShell sandboxes broken by the LAN containment DROP.
#
#   sudo bash ops/fix-sandbox-dns.sh           # apply, then persist
#   sudo bash ops/fix-sandbox-dns.sh --check   # report only, change nothing
#   sudo bash ops/fix-sandbox-dns.sh --revert  # remove the exception
#
# WHY THIS EXISTS
# ops/fix-sandbox-iptables.sh (run 2026-08-21) added, correctly:
#     -s 172.19.0.0/16 -d 10.0.4.0/22 -j DROP
# Docker's embedded resolver (127.0.0.11) inside every openshell-docker sandbox
# forwards to exactly ONE upstream, 10.0.4.1 — the LAN router — which lives
# inside that DROPped range. So the rule also severed all DNS: every lookup
# SERVFAILs and the L7 proxy reports
#     DENIED ... [engine:ssrf] [reason:DNS resolution failed ...]
# Gandalf's Telegram adapter went silent 2026-08-20, the day before.
#
# The old stack on 172.18.0.0/16 carries the SAME DROP and is unaffected, because
# Docker gave it a different upstream: ExtServers: [host(127.0.0.53)]. Only the
# 172.19 network depends on a LAN address to resolve.
#
# This adds the narrowest possible exception: one host, one port, UDP+TCP.
# All other LAN containment stays intact — 10.0.4.0/22 remains DROPped except
# for :53 on the resolver itself.
#
# KNOWN LIMITATION — this is the tactical fix.
# 10.0.4.1 is NOT NextDNS-filtered (nextdns is `listen localhost:53`, host-only),
# so sandbox lookups bypass that safety layer. This restores parity with the old
# 172.18 stack rather than creating a new gap, but it is not the end state. The
# durable fix is a socat bridge on 172.19.0.1:53 -> 127.0.0.1:53, matching the
# gandalf-*-bridge pattern already used for vLLM and argo, which puts sandbox DNS
# behind NextDNS without moving nextdns off localhost. Remove this rule
# (--revert) once that lands.

set -euo pipefail

RESOLVER="10.0.4.1"
SANDBOX_NET="172.19.0.0/16"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; RST=$'\033[0m'
info() { printf '%s[✓]%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
fail() { printf '%s[✗]%s %s\n' "$RED" "$RST" "$1"; }
note() { printf '%s[i]%s %s\n' "$CYN" "$RST" "$1"; }

MODE="apply"
case "${1:-}" in
    --check)  MODE="check" ;;
    --revert) MODE="revert" ;;
    "")       MODE="apply" ;;
    *) echo "usage: $0 [--check|--revert]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    fail "must run as root (iptables needs it): sudo bash $0 ${1:-}"
    exit 1
fi

# UDP is what resolvers actually use; TCP is the fallback for large answers
# (and is required once responses exceed the UDP limit).
PROTOS="udp tcp"

rule_for() { printf -- '-s %s -d %s/32 -p %s --dport 53 -j ACCEPT' "$SANDBOX_NET" "$RESOLVER" "$1"; }

if [ "$MODE" = "revert" ]; then
    removed=0
    for p in $PROTOS; do
        # shellcheck disable=SC2046
        if iptables -C DOCKER-USER $(rule_for "$p") 2>/dev/null; then
            # shellcheck disable=SC2046
            iptables -D DOCKER-USER $(rule_for "$p")
            info "removed $p/53 exception"; removed=$((removed+1))
        else
            note "$p/53 exception not present"
        fi
    done
    [ "$removed" -gt 0 ] && netfilter-persistent save >/dev/null && info "persisted"
    exit 0
fi

missing=0
for p in $PROTOS; do
    # shellcheck disable=SC2046
    if iptables -C DOCKER-USER $(rule_for "$p") 2>/dev/null; then
        info "$p/53 exception: present"
    else
        warn "$p/53 exception: MISSING"; missing=$((missing+1))
    fi
done

if [ "$missing" -eq 0 ]; then
    info "nothing to do"
    exit 0
fi

if [ "$MODE" = "check" ]; then
    warn "$missing rule(s) missing. Re-run without --check to apply."
    exit 1
fi

# -I puts the ACCEPT ABOVE the existing DROP. Order is the whole point: appending
# would place it after the DROP, where it can never match.
for p in $PROTOS; do
    # shellcheck disable=SC2046
    iptables -C DOCKER-USER $(rule_for "$p") 2>/dev/null && continue
    # shellcheck disable=SC2046
    iptables -I DOCKER-USER 1 $(rule_for "$p")
    info "added: $(rule_for "$p")"
done

echo ""
netfilter-persistent save >/dev/null && info "persisted across reboots"

echo ""
note "verify from a sandbox:"
note "  docker exec -u sandbox <sandbox> getent hosts api.telegram.org"
note "confirm LAN containment still holds (should TIME OUT, not connect):"
note "  docker exec -u root <sandbox> timeout 6 python3 -c \\"
note "    \"import socket;socket.create_connection(('$RESOLVER',22),5)\""
