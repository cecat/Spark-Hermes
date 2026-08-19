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

# A rebuild wipes the sandbox's writable layer, so this backup is the only way
# back. It must be REAL: ops/snapshot.sh was used here until 2026-08-19, and it
# reports success over an empty result — it aborts on the 1.2 GB state.db and
# takes the whole run down with it, so snapshots v18 and v20 contain nothing but
# a manifest and SOUL.md. Piping it through `tail` also masked its exit status.
# ops/backup-sandbox.sh is manifest-driven and exits non-zero when anything
# fails; do not swap it back or wrap it in a pipe.
note "Taking pre-rebuild backup (this is the rollback point)..."
if ! bash "$(dirname "$0")/backup-sandbox.sh"; then
    fail "Pre-rebuild backup FAILED — refusing to rebuild without a rollback point."
fi

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
