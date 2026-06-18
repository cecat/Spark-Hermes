#!/usr/bin/env bash
# Take a NemoClaw snapshot of the gandalf sandbox.
#
# Usage:
#   bash snapshot.sh                   # auto-named timestamp
#   bash snapshot.sh pre-experiment    # named with a tag
#
# Snapshots are stored at ~/.nemoclaw/rebuild-backups/gandalf/.
# Restore: nemohermes gandalf snapshot restore <name|version|timestamp>
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

TAG="${1:-}"
NAME="snap-$(date +%Y-%m-%dT%H-%M-%SZ)"
[ -n "$TAG" ] && NAME="${NAME}-${TAG}"

note "Creating snapshot: $NAME"
nemohermes gandalf snapshot create --name "$NAME" 2>&1 | head -5

info "Done. Recent snapshots:"
nemohermes gandalf snapshot list 2>&1 | head -10
