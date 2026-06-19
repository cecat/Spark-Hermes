#!/usr/bin/env bash
# Wrap `nemohermes gandalf rebuild` so the post-bringup state that the
# rebuild silently drops gets restored in the same command.
#
# Use this instead of calling `nemohermes gandalf rebuild` directly.

set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
load_hermes_env
require_hermes_config

note "Taking pre-rebuild snapshot..."
bash "$(dirname "$0")/snapshot.sh" pre-rebuild 2>&1 | tail -3

note "Running nemohermes gandalf rebuild..."
# Forward env vars rebuild expects (credentials for providers, Slack tokens
# for messaging-channel re-registration).
NEMOCLAW_MODEL=$(hermes_cfg inference.model) \
COMPATIBLE_ANTHROPIC_API_KEY=${COMPATIBLE_ANTHROPIC_API_KEY:-catlett} \
OPENAI_API_KEY=${OPENAI_API_KEY:-not-required} \
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}" \
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}" \
SLACK_HOME_CHANNEL="${SLACK_HOME_CHANNEL:-}" \
SLACK_ALLOWED_USERS="${SLACK_ALLOWED_USERS:-}" \
SLACK_ALLOWED_CHANNELS="${SLACK_ALLOWED_CHANNELS:-}" \
  yes y | nemohermes gandalf rebuild --yes

note "Rebuild done. Restoring post-bringup state..."
bash "$(dirname "$0")/post-rebuild.sh"

info "Rebuild complete and state restored. Verify with: bash $(dirname "$0")/status.sh"
