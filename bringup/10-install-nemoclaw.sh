#!/usr/bin/env bash
set -euo pipefail
export NEMOCLAW_AGENT=hermes
export NEMOCLAW_PROVIDER=anthropicCompatible
export NEMOCLAW_ENDPOINT_URL=http://127.0.0.1:44497
export COMPATIBLE_ANTHROPIC_API_KEY=catlett
export NEMOCLAW_PROVIDER_KEY=catlett
export NEMOCLAW_MODEL=claudeopus47
export NEMOCLAW_SANDBOX_NAME=gandalf
export NEMOCLAW_POLICY_MODE=suggested
export NEMOCLAW_POLICY_TIER=balanced
export NEMOCLAW_NO_EXPRESS=1
export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
export NEMOCLAW_EXPERIMENTAL=1
export NEMOCLAW_INSTALL_TAG=lkg
# Run from the cloned source so sibling scripts (setup-jetson.sh, etc.) resolve.
exec bash ~/gandalf-bringup/nemoclaw-src/scripts/install.sh --non-interactive --yes-i-accept-third-party-software
