#!/usr/bin/env bash
# Render gandalf/soul/*.md into a single /sandbox/.hermes/SOUL.md.
#
# WHY THIS EXISTS (read before "simplifying" it back):
#   This script replaces the old apply-memories.sh, which pushed each file to
#   /sandbox/.hermes/memories/<name>.md. That directory is read by NOTHING.
#   Verified against Hermes v0.14.0 source on 2026-07-28:
#     MemoryStore.load_from_disk()  (tools/memory_tool.py:126-132)
#     opens ONLY MEMORY.md and USER.md — hard-coded filenames, no glob, no
#     numeric-prefix scan. There is no memory.files / memory.dir / context.files
#     config key in any Hermes version. The numbered-file convention was
#     invented by this repo and never loaded. Six weeks of edits went nowhere.
#
#   SOUL.md IS read, on every agent construction:
#     load_soul_md()               (agent/prompt_builder.py:1305) — read_text(),
#     called from _build_system_prompt_parts() (run_agent.py:6082)
#          -> _build_system_prompt()          (run_agent.py:6264)
#     Result is cached per AIAgent instance, so changes land on the next NEW
#     SESSION (/new in chat, gateway start, or post-compression rebuild).
#     No gateway restart required.
#
#   Cap is CONTEXT_FILE_MAX_CHARS = 20000. Over that, Hermes truncates
#   head+tail with a marker in the middle and you silently lose the middle of
#   your guardrails. This script refuses to upload rather than let that happen.
#
#   See docs/HERMES-LOAD-PATHS.md for the full map of what loads and what doesn't.
#
# Substitution: any ${a.b.c} in a source file is replaced with the matching
# value from ~/.hermes/config.yaml (host-side) before concatenation.
#
# Idempotent: re-running with no edits is a no-op.
#
# Flags:
#   --dry-run   Render and size-check, print the result, upload nothing.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
require_hermes_config

MAX_CHARS=20000

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

REPO=$(repo_root)
SRC="$REPO/gandalf/soul"
DST=/sandbox/.hermes/SOUL.md
AGENT=$(hermes_cfg agent.name)
CONTAINER=$(gandalf_container)
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

[ -d "$SRC" ] || fail "No soul directory at $SRC"
FILES=$(find "$SRC" -maxdepth 1 -type f -name '*.md' | sort)
[ -n "$FILES" ] || fail "No .md files in $SRC — refusing to upload an empty SOUL.md."

note "Source: $SRC"
note "Target: $CONTAINER:$DST"

BUILT="$STAGING/SOUL.md"
: > "$BUILT"

# Render each source file through config-substitution, then append.
for f in $FILES; do
  base=$(basename "$f")
  python3 - "$f" "$HERMES_CONFIG" "$STAGING/part" <<'PYEOF'
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
  cat "$STAGING/part" >> "$BUILT"
  printf '\n\n' >> "$BUILT"
  info "rendered: $base"
done

SIZE=$(wc -c < "$BUILT" | tr -d ' ')
if [ "$SIZE" -gt "$MAX_CHARS" ]; then
  fail "Rendered SOUL.md is $SIZE chars, over the $MAX_CHARS limit.
Hermes would truncate the MIDDLE of the file (head+tail kept), silently dropping
guardrails. Trim gandalf/soul/*.md, or move on-demand material into a skill
(gandalf/skills/) which has no such cap. Nothing was uploaded."
fi
info "size: $SIZE / $MAX_CHARS chars ($(( SIZE * 100 / MAX_CHARS ))% used)"

if [ "$DRY" -eq 1 ]; then
  note "Dry run — rendered output follows, nothing uploaded:"
  echo "────────────────────────────────────────────────────────"
  cat "$BUILT"
  echo "────────────────────────────────────────────────────────"
  exit 0
fi

# Compare against what's already installed.
LOCAL_H=$(sha256sum "$BUILT" | awk '{print $1}')
REMOTE_H=$(docker exec -u sandbox "$CONTAINER" sh -c "sha256sum $DST 2>/dev/null" | awk '{print $1}' || echo "")

if [ "$LOCAL_H" = "$REMOTE_H" ]; then
  info "SOUL.md already in sync — nothing to do."
  exit 0
fi

openshell sandbox upload "$AGENT" "$BUILT" "$DST" >/dev/null \
  || fail "upload failed for SOUL.md"
info "pushed: SOUL.md ($SIZE chars)"

cat <<'EOF'

  SOUL.md is cached per agent session. To pick it up:
    - send /new in a chat with the agent, or
    - wait for the next session start.
  A gateway restart is NOT required.

  Verify: start a new session and ask the agent something only the new
  SOUL.md would let it answer.
EOF
