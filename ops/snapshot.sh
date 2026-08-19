#!/usr/bin/env bash
# Take a NemoClaw snapshot of the gandalf sandbox.
#
# Usage:
#   bash snapshot.sh                   # auto-named timestamp
#   bash snapshot.sh pre-experiment    # named with a tag
#
# Snapshots are stored at ~/.nemoclaw/rebuild-backups/gandalf/.
# Restore: nemohermes gandalf snapshot restore <name|version|timestamp>
#
# ⚠️ DO NOT USE THIS AS A ROLLBACK POINT — use ops/backup-sandbox.sh.
#
# Known broken on the current deployment. `snapshot create` aborts on the
# 1.2 GB runtime/state.db and takes the whole run down with it, then registers
# the snapshot anyway: v18 (2026-07-29) and v20 (2026-08-18) contain nothing
# but rebuild-manifest.json and SOUL.md. Root cause is size, not locking —
# `openshell sandbox download` cannot move 1.2 GB before timing out. It is
# compounded by Gandalf's registry entry being incomplete for lifecycle
# operations (missing fromDockerfile, gatewayName, gatewayPort,
# nemoclawVersion), which the platform upgrade is expected to fix.
#
# This script now surfaces the failure instead of hiding it behind `| head`,
# but a passing exit code still does NOT mean the snapshot has contents.
# Verify before trusting one.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

TAG="${1:-}"
NAME="snap-$(date +%Y-%m-%dT%H-%M-%SZ)"
[ -n "$TAG" ] && NAME="${NAME}-${TAG}"

warn "snapshot.sh is known to produce EMPTY snapshots on this deployment."
warn "For a real rollback point use: bash ops/backup-sandbox.sh"

note "Creating snapshot: $NAME"
# No pipe: a pipeline would mask the exit status, which is how the empty-backup
# failure went unnoticed for weeks.
if ! nemohermes gandalf snapshot create --name "$NAME"; then
    fail "snapshot create FAILED — do not treat this as a rollback point."
fi

info "Done. Recent snapshots:"
nemohermes gandalf snapshot list 2>&1 | head -10
