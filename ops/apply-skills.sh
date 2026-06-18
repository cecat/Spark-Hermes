#!/usr/bin/env bash
# Push gandalf/skills/*/ into /sandbox/.hermes/skills/.
# Uses the `nemohermes <sb> skill install <path>` command, which handles
# the SKILL.md validation.
#
# Idempotent. Re-running with no changes is fine; skill install overwrites
# the same destination.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

REPO=$(repo_root)
SRC="$REPO/gandalf/skills"
[ -d "$SRC" ] || fail "No skills directory at $SRC"

# Find each skill: directories containing a SKILL.md
SKILLS=$(find "$SRC" -mindepth 2 -maxdepth 2 -name 'SKILL.md' | sed 's|/SKILL.md$||')
if [ -z "$SKILLS" ]; then
  note "No skills found under $SRC (no <dir>/SKILL.md files)."
  note "To add one, see ops/add-a-skill.md."
  exit 0
fi

for skill_dir in $SKILLS; do
  name=$(basename "$skill_dir")
  note "Installing skill: $name (from $skill_dir)"
  nemohermes gandalf skill install "$skill_dir" || fail "skill install failed for $name"
  info "Installed: $name"
done

info "All skills applied. Hermes will pick them up on the next session start or when a matching tag is requested."
