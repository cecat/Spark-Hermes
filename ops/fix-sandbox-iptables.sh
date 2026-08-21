#!/usr/bin/env bash
# Extend the three DOCKER-USER containment rules to the OpenShell sandbox network.
#
#   sudo bash ops/fix-sandbox-iptables.sh            # apply, then persist
#   sudo bash ops/fix-sandbox-iptables.sh --check     # report only, change nothing
#
# WHY THIS EXISTS
# The rules documented in OpenClaw-Tutorial §2.4 are scoped to 172.18.0.0/16 —
# the old qwen3-coder-next_nim_net that the OpenClaw gateway and its sandboxes
# live on. OpenShell puts its sandboxes on a DIFFERENT network (openshell-docker,
# 172.19.0.0/16), so those rules never match them. Verified 2026-08-21: a new
# sandbox opened a TCP connection to a LAN host on port 22; the old sandbox
# times out on the same target.
#
# This script does not invent policy. It applies the SAME three rules to the
# sandbox networks that are missing them.
#
# NOT COVERED HERE: reaching a Tailscale peer that has a direct LAN path. That
# affects the old stack equally (see docs/FOLLOWUPS.md) and is a separate issue.

set -euo pipefail

LAN_SUBNET="10.0.4.0/22"
TAILSCALE_CGNAT="100.64.0.0/10"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; RST=$'\033[0m'
info() { printf '%s[✓]%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
fail() { printf '%s[✗]%s %s\n' "$RED" "$RST" "$1"; }
note() { printf '%s[i]%s %s\n' "$CYN" "$RST" "$1"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "must run as root (iptables needs it): sudo bash $0 ${1:-}"
    exit 1
fi

# Every Docker network that hosts a container, not just the two we know about.
# Assuming a fixed subnet list is the exact bug this script fixes.
mapfile -t SUBNETS < <(
    docker network ls --format '{{.Name}}' \
    | while read -r net; do
        docker network inspect "$net" \
            --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null \
            | grep -E '^(172|10|192)\.' || true
      done | sort -u
)

[ "${#SUBNETS[@]}" -eq 0 ] && { fail "no Docker subnets found — is Docker running?"; exit 1; }

note "Docker subnets found: ${SUBNETS[*]}"
echo ""

missing=0
declare -a TO_ADD

for subnet in "${SUBNETS[@]}"; do
    # -C tests for a rule without adding it.
    for spec in \
        "-s $subnet -d $LAN_SUBNET -j DROP|LAN" \
        "-s $subnet -d $TAILSCALE_CGNAT -j DROP|Tailscale CGNAT" \
        "-s $subnet -p tcp --dport 22 -j DROP|SSH"
    do
        rule="${spec%%|*}"; label="${spec##*|}"
        # shellcheck disable=SC2086
        if iptables -C DOCKER-USER $rule 2>/dev/null; then
            info "$subnet → $label: present"
        else
            warn "$subnet → $label: MISSING"
            TO_ADD+=("$rule")
            missing=$((missing + 1))
        fi
    done
done

echo ""
if [ "$missing" -eq 0 ]; then
    info "all subnets covered — nothing to do"
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "$missing rule(s) missing. Re-run without --check to apply."
    exit 1
fi

for rule in "${TO_ADD[@]}"; do
    # shellcheck disable=SC2086
    iptables -I DOCKER-USER $rule
    info "added: $rule"
done

echo ""
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null && info "persisted across reboots"
else
    warn "netfilter-persistent not installed — rules will NOT survive a reboot"
fi

echo ""
note "verify from a sandbox (a DROP hangs to timeout; refused/connected means the packet arrived):"
note "  docker exec -u sandbox <sandbox> timeout 6 bash -c 'cat </dev/null >/dev/tcp/<a-lan-host>/22'"
