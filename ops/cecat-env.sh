#!/usr/bin/env bash
# Environment for driving the SECOND control plane (port 8090) where cecat lives.
#
# Source this, never run it:  source ops/cecat-env.sh
#
# Why this exists: Gandalf runs on the port-8080 control plane with NemoClaw
# v0.0.55 + OpenShell 0.0.44, and that stack is deliberately FROZEN. cecat runs
# on a second control plane (port 8090) with NemoClaw v0.0.108 + OpenShell
# 0.0.101. Neither is installed globally for cecat's sake — the global
# `nemoclaw`/`openshell` on PATH stay pinned to Gandalf's versions so every
# existing ops script keeps working untouched.
#
# This file makes the newer pair reachable in ONE shell only. Nothing here is
# persistent, and closing the shell reverts everything.
#
# Verified 2026-08-21: with NEMOCLAW_GATEWAY_PORT=8090 the state root resolves
# to ~/.nemoclaw/gateways/8090 (separate registry, separate inference route),
# while 8080 resolves to plain ~/.nemoclaw. Confirmed against
# src/lib/state/state-root.ts.

NEMOCLAW_108="$HOME/gandalf-bringup/nemoclaw-src-v0.0.108"
OPENSHELL_101_BIN="$HOME/gandalf-bringup/openshell-0.0.101/bin"

# The 0.0.101 CLI must come first on PATH; the v0.0.108 CLI refuses to talk to
# an 0.0.44 client (blueprint.yaml pins min=max=0.0.101).
export PATH="$OPENSHELL_101_BIN:$HOME/.nvm/versions/node/v22.22.3/bin:$PATH"

# Selects the second control plane. Drives BOTH the NemoClaw state root and
# which OpenShell gateway the CLI talks to.
export NEMOCLAW_GATEWAY_PORT=8090
export OPENSHELL_GATEWAY=nemoclaw-8090

# Deliberately NOT setting OPENSHELL_GATEWAY_ENDPOINT. `nemoclaw onboard`
# hard-refuses when it is set (openshell-gateway-endpoint-guard.js) because a
# direct endpoint can bypass the gateway recorded for the sandbox. The gateway
# NAME above is the correct selector; the CLI resolves the endpoint and its
# mTLS material from stored metadata.

# `nemoclaw` on PATH is v0.0.55 (Gandalf's). Use this for the v0.0.108 CLI.
nemoclaw108() { node "$NEMOCLAW_108/dist/nemoclaw.js" "$@"; }
export -f nemoclaw108

# ⚠️ `sandbox 'X' is not ready (phase: Unspecified)` means you did NOT source
# this file. The v0.0.108 CLI shells out to whatever `openshell` is first on
# PATH; against Gandalf's 0.0.44 binary the phase field decodes as Unspecified
# even though `openshell sandbox list` reports Ready. It is a CLI/gateway
# version mismatch, NOT a sandbox problem — do not wait, retry, or recreate.
#
# ⚠️ Several v0.0.108 commands (`onboard`, `cecat exec`, …) call
# `openshell gateway select` and leave nemoclaw-8090 as the GLOBAL default.
# That makes Gandalf's own tooling look broken — `ops/status.sh` reports
# "Sandbox phase: unknown" and `openshell inference get` errors, because they
# are then querying cecat's plane. Nothing is actually wrong. Restore with:
#
#     openshell gateway select nemoclaw
#
# `ops/status.sh` now does this itself. Run it after any cecat work.

echo "cecat env active:"
echo "  openshell : $(command -v openshell) ($(openshell --version 2>/dev/null))"
echo "  nemoclaw108: v0.0.108 sidecar at $NEMOCLAW_108"
echo "  gateway   : $OPENSHELL_GATEWAY (port $NEMOCLAW_GATEWAY_PORT)"
echo "  state root: ~/.nemoclaw/gateways/$NEMOCLAW_GATEWAY_PORT"
echo
echo "Gandalf's plane (port 8080, v0.0.55 / 0.0.44) is untouched in other shells."
