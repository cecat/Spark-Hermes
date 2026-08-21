#!/usr/bin/env bash
# Environment for driving the THIRD control plane (port 8091) where luoji lives.
#
# Source this, never run it:  source ops/luoji-env.sh
#
# One control plane per agent. See ops/cecat-env.sh for the full rationale; the
# short version is that the OpenShell inference route (what `inference.local`
# resolves to) is ONE PER CONTROL PLANE, shared by every sandbox on it. luoji
# runs claudeopus47 and cecat runs claudesonnet46, so they cannot share a plane
# without one of them silently re-pointing the other's model.
#
# Planes on this host:
#   :8080  gandalf  NemoClaw v0.0.55  / OpenShell 0.0.44   (global install, FROZEN)
#   :8090  cecat    NemoClaw v0.0.108 / OpenShell 0.0.101  (sidecar)
#   :8091  luoji    NemoClaw v0.0.108 / OpenShell 0.0.101  (sidecar)  ← this file

NEMOCLAW_108="$HOME/gandalf-bringup/nemoclaw-src-v0.0.108"
OPENSHELL_101_BIN="$HOME/gandalf-bringup/openshell-0.0.101/bin"

export PATH="$OPENSHELL_101_BIN:$HOME/.nvm/versions/node/v22.22.3/bin:$PATH"

export NEMOCLAW_GATEWAY_PORT=8091
export OPENSHELL_GATEWAY=nemoclaw-8091

# Deliberately NOT setting OPENSHELL_GATEWAY_ENDPOINT — `nemoclaw onboard`
# hard-refuses when it is set (openshell-gateway-endpoint-guard.js).

# ⚠️ v0.0.108 commands (`onboard`, `exec`, …) flip the GLOBAL default gateway as
# a side effect, which makes Gandalf's tooling look broken. Restore with:
#     openshell gateway select nemoclaw
# ops/status.sh already pins -g nemoclaw and an absolute binary path, so it is
# immune; other Gandalf tooling is not.
#
# ⚠️ `sandbox 'X' is not ready (phase: Unspecified)` means you did NOT source
# this file. The v0.0.108 CLI shells out to whatever `openshell` is first on
# PATH; against Gandalf's 0.0.44 binary the phase field decodes as Unspecified
# even though `openshell sandbox list` reports Ready. It is a CLI/gateway
# version mismatch, NOT a sandbox problem — do not wait, retry, or recreate.

echo "luoji env active:"
echo "  openshell : $(command -v openshell) ($(openshell --version 2>/dev/null))"
echo "  nemoclaw  : v0.0.108 sidecar at $NEMOCLAW_108"
echo "  gateway   : $OPENSHELL_GATEWAY (port $NEMOCLAW_GATEWAY_PORT)"
echo "  state root: ~/.nemoclaw/gateways/$NEMOCLAW_GATEWAY_PORT"
