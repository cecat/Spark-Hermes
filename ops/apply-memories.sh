#!/usr/bin/env bash
# Push gandalf/memories/*.md into /sandbox/.hermes/memories/.
#
# Substitution: any ${a.b.c} in a memory file gets replaced with the matching
# value from ~/.hermes/config.yaml before upload. That lets memories in the
# repo refer to operator-specific values (operator.name, slack.home_channel, etc.)
# without hard-coding them.
#
# Idempotent: re-running with no edits is a no-op.
#
# Flags:
#   --dry-run   Show what would be uploaded without uploading.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
require_hermes_config

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

REPO=$(repo_root)
SRC="$REPO/gandalf/memories"
DST=/sandbox/.hermes/memories
AGENT=$(hermes_cfg agent.name)
CONTAINER=$(gandalf_container)
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

[ -d "$SRC" ] || fail "No memories directory at $SRC"
FILES=$(find "$SRC" -maxdepth 1 -type f -name '*.md' | sort)
[ -n "$FILES" ] || { note "No .md files in $SRC; nothing to push."; exit 0; }

note "Source: $SRC"
note "Target: $CONTAINER:$DST"

# Render each memory through config-substitution into a staging file.
for f in $FILES; do
  base=$(basename "$f")
  python3 - "$f" "$HERMES_CONFIG" "$STAGING/$base" <<'PYEOF'
import re, sys, yaml
src, cfg_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = yaml.safe_load(open(cfg_path))
def sub(m):
    key = m.group(1); cur = cfg
    for k in key.split('.'):
        cur = cur.get(k) if isinstance(cur, dict) else None
        if cur is None: return m.group(0)
    return str(cur)
text = re.sub(r'\$\{([a-zA-Z0-9_.]+)\}', sub, open(src).read())
open(out, 'w').write(text)
PYEOF
done

# Compute remote hashes of currently-installed memories
REMOTE_HASHES=$(docker exec -u sandbox "$CONTAINER" sh -c "cd $DST 2>/dev/null && sha256sum *.md 2>/dev/null" || echo "")

CHANGES=0
for f in $STAGING/*.md; do
  base=$(basename "$f")
  local_h=$(sha256sum "$f" | awk '{print $1}')
  remote_h=$(echo "$REMOTE_HASHES" | awk -v n="$base" '$2==n {print $1; exit}')
  if [ "$local_h" = "$remote_h" ]; then
    info "unchanged: $base"
  else
    CHANGES=$((CHANGES + 1))
    if [ "$DRY" -eq 1 ]; then
      warn "would push: $base"
    else
      openshell sandbox upload "$AGENT" "$f" "$DST/$base" >/dev/null && info "pushed:    $base" || fail "upload failed for $base"
    fi
  fi
done

if [ "$DRY" -eq 1 ]; then
  note "Dry run: $CHANGES file(s) would be pushed."
else
  if [ "$CHANGES" -eq 0 ]; then
    info "All memories already in sync."
  else
    info "Pushed $CHANGES file(s). Hermes picks up memory changes on the next turn — no restart needed."
  fi
fi
