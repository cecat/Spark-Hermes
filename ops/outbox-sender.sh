#!/usr/bin/env bash
# DEPRECATED — this host-side sender has been replaced by a sandbox-side
# Hermes cron job. See:
#   - ~/code/Spark-Hermes/sandbox-scripts/outbox-send.py  (the actual sender)
#   - ~/.hermes/config.yaml cron.jobs[] entry "outbox-send" (the schedule)
#   - ~/code/Spark-Hermes/ops/post-rebuild.sh              (the deploy hook)
#
# Why the move: the host path had to docker-exec into the sandbox per call,
# which does NOT inherit the OpenShell L7 proxy env vars (HTTPS_PROXY +
# custom CA bundle). Without those, gmail.googleapis.com is unreachable from
# the spawned process, producing a `gaierror` that the recipient validator
# silently swallowed — leading to false rejections (operator+agent-only
# allowlist) AND failed sends. The fix is structural: only the gateway-side
# Python process talks to Google APIs, since the gateway already has the
# right network namespace.
#
# This script is kept as a no-op stub so the existing host crontab entry
# (`outbox-processor.sh && outbox-sender.sh`) still exits 0. Remove the
# crontab entry on next housekeeping pass — see the README.
#
# Removed 2026-06-18 as part of the host-vs-sandbox-path consolidation.

# Print a short notice once so any human running this by hand learns what happened.
if [ -t 1 ]; then
  echo "[outbox-sender.sh] DEPRECATED — see file header. No-op; the sandbox-side"
  echo "                   'outbox-send' Hermes cron job handles sends now."
fi
exit 0
