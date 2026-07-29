#!/usr/bin/env bash
# Pull the FALDA provider's per-turn telemetry out of the Gandalf sandbox overlay
# to a durable host location. Phase 5c (REQ-1 observability).
#
# The provider runs INSIDE the sandbox and writes JSONL to
# /sandbox/.hermes/telemetry/. That's the writable overlay — a rebuild wipes it.
# This script copies it to ~/.falda/telemetry/ (0600), which persists.
#
# The telemetry is append-only JSONL, so we copy the whole file each tick and let
# the host copy be the durable superset. Cheap (small files) and simple; no
# offset bookkeeping needed. If it ever grows large, switch to an incremental
# tail — but the point is research data safety, so a full copy is the safe default.
#
# Contains Charlie's real conversations (hashes + counts, but message content in
# nothing except what the provider chose to log — currently hashes only). Kept
# out of any repo: ~/.falda/telemetry is gitignored at the fabric level.
#
# Idempotent; safe to run on a timer.
set -eu

CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^openshell-gandalf-' | head -1)
[ -n "$CONTAINER" ] || { echo "[pull-telemetry] no gandalf container; skipping" >&2; exit 0; }

SRC_DIR="/sandbox/.hermes/telemetry"
DEST_DIR="${FALDA_TELEMETRY_DIR:-$HOME/.falda/telemetry}"
mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR" 2>/dev/null || true

# List files in the sandbox telemetry dir (may be empty / absent early on).
FILES=$(docker exec -u sandbox "$CONTAINER" sh -c "ls -1 $SRC_DIR 2>/dev/null" || true)
[ -n "$FILES" ] || { echo "[pull-telemetry] nothing to pull yet"; exit 0; }

for f in $FILES; do
  # docker cp preserves content; we then tighten perms on the host copy.
  docker cp "$CONTAINER:$SRC_DIR/$f" "$DEST_DIR/$f" 2>/dev/null || {
    echo "[pull-telemetry] failed to copy $f" >&2; continue; }
  chmod 600 "$DEST_DIR/$f" 2>/dev/null || true
done
echo "[pull-telemetry] synced $(echo "$FILES" | wc -w) file(s) -> $DEST_DIR"
