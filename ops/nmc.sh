#!/usr/bin/env bash
# Run a NemoClaw command against a SECONDARY agent's own control plane.
#
#   bash ops/nmc.sh <agent> <command...>
#   bash ops/nmc.sh luoji policy list
#   bash ops/nmc.sh cecat policy add --from-file bringup/50-openshell-policies/cecat-slack-egress.yaml --yes
#
# WHY THIS EXISTS — do not bypass it.
#
# `nemoclaw` on PATH is v0.0.55 (Gandalf's, deliberately frozen). That version
# predates per-port state and is hardcoded to ONE control plane: GATEWAY_NAME is
# a constant, re-stamped into OPENSHELL_GATEWAY throughout onboard.ts. Point it
# at an agent that lives on :8090/:8091 and it does not fail — it "helpfully"
# relaunches a gateway on that port using ITS defaults: plaintext where the
# sandbox requires mTLS, and OPENSHELL_DB_URL pointing at Gandalf's database. It
# also rewrites Gandalf's own gateway entry in place.
#
# That is not hypothetical. `nemoclaw luoji policy-list` did exactly this on
# 2026-09-01 and put luoji into a 93-restart loop; recovery needed
# ops/agent-planes.sh start plus a backup restore. Note that the command was a
# read-only-sounding `policy-list` — the damage comes from the binary, not the
# verb, so there is no "safe" subcommand to hand to the global CLI.
#
# The correct invocation is the v0.0.108 sidecar with NEMOCLAW_GATEWAY_PORT set
# and any ambient gateway selection scrubbed, which is what this script does.
# Same guard rails as the osh() helper in ops/agent-planes.sh.
#
# Gandalf is NOT reachable here, by design: he is on the frozen v0.0.55 :8080
# plane and uses `nemohermes gandalf ...` instead.
set -eu

OPENSHELL_101_BIN="$HOME/gandalf-bringup/openshell-0.0.101/bin"
NEMOCLAW_108="$HOME/gandalf-bringup/nemoclaw-src-v0.0.108/dist/nemoclaw.js"
NODE_BIN="$HOME/.nvm/versions/node/v22.22.3/bin/node"

# agent:port pairs. Keep in sync with PLANES in ops/agent-planes.sh.
declare -A PLANE_PORT=( [cecat]=8090 [luoji]=8091 )

AGENT="${1:-}"; shift || true
PORT="${PLANE_PORT[$AGENT]:-}"

if [ -z "$AGENT" ] || [ $# -eq 0 ]; then
    echo "usage: bash ops/nmc.sh <agent> <command...>" >&2
    echo "agents: ${!PLANE_PORT[*]}" >&2
    exit 2
fi
if [ -z "$PORT" ]; then
    echo "unknown agent '$AGENT' (known: ${!PLANE_PORT[*]})" >&2
    echo "gandalf is on the frozen :8080 plane — use 'nemohermes gandalf ...'" >&2
    exit 2
fi
[ -f "$NEMOCLAW_108" ] || { echo "missing v0.0.108 sidecar: $NEMOCLAW_108" >&2; exit 1; }

# The 0.0.101 openshell binary must be first on PATH: the v0.0.108 CLI shells
# out to whatever `openshell` it finds, and against Gandalf's 0.0.44 binary the
# sandbox phase decodes as `Unspecified` even on a healthy sandbox.
exec env -u OPENSHELL_GATEWAY -u OPENSHELL_GATEWAY_ENDPOINT \
    NEMOCLAW_GATEWAY_PORT="$PORT" \
    OPENSHELL_GATEWAY="nemoclaw-${PORT}" \
    PATH="$OPENSHELL_101_BIN:$(dirname "$NODE_BIN"):$PATH" \
    "$NODE_BIN" "$NEMOCLAW_108" "$AGENT" "$@"
