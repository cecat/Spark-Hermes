#!/usr/bin/env bash
# Apply every YAML in bringup/50-openshell-policies/ to the gandalf sandbox.
# Idempotent — re-applying a policy that's already loaded is a no-op
# (NemoClaw reports "Policy unchanged").
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

REPO=$(repo_root)
DIR="$REPO/bringup/50-openshell-policies"
[ -d "$DIR" ] || fail "Missing $DIR"

FILES=$(find "$DIR" -maxdepth 1 -type f -name '*.yaml' | sort)
[ -n "$FILES" ] || { warn "No .yaml policies in $DIR"; exit 0; }

for f in $FILES; do
  name=$(basename "$f")
  note "Applying: $name"
  nemohermes gandalf policy-add --from-file "$f" --yes 2>&1 | grep -E '(✓|preset:|Endpoints|unchanged|Applied|Error|error)' | sed 's/^/   /'
done

info "Done. Current policy presets:"
nemohermes gandalf policy-list 2>&1 | grep -E '●|○' | head -30
