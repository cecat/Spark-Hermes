#!/usr/bin/env bash
# Push the FALDA memory provider plugin into the Gandalf sandbox overlay and
# (optionally) activate it. Phase 5c.
#
# The sandbox writable layer is wiped by a rebuild, so this plugin — like skills
# and Google deps — must be re-applied from the repo. NEVER hand-place it in the
# container. This script is also wired into ops/post-rebuild.sh.
#
# Idempotent. Re-running copies the current plugin dir over the old one.
#
# Usage:
#   bash ops/apply-memory-provider.sh            # copy plugin + telemetry dir only
#   bash ops/apply-memory-provider.sh --activate # also set memory.provider: falda
#   bash ops/apply-memory-provider.sh --deactivate
#   bash ops/apply-memory-provider.sh --native-memory on|off
#
# --native-memory controls Hermes' BUILT-IN memory (MEMORY.md + USER.md), which
# is independent of and additive to the FALDA provider: run_agent.py appends the
# provider's block after the built-in blocks, so both can be on at once. Hermes
# defaults both flags to True; ops/phase0-runner.py forces them off at the start
# of every cell and never restores them, so a finished grid run leaves the agent
# with no native memory.
#
# After --activate/--deactivate/--native-memory you MUST restart the Hermes
# gateway for the change to load. This script does NOT restart it (operator's
# call; the gateway is not a shared service but restarts drop in-flight sessions).
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

REPO=$(repo_root)
CONTAINER=$(gandalf_container)
SRC="$REPO/gandalf/plugins/falda"
DEST_PARENT="/sandbox/.hermes/plugins"
DEST="$DEST_PARENT/falda"
CONFIG="/sandbox/.hermes/config.yaml"

[ -d "$SRC" ] || fail "No plugin at $SRC"
[ -f "$SRC/__init__.py" ] || fail "$SRC missing __init__.py"

ACTION="copy"
NATIVE_WANT=""
case "${1:-}" in
  --activate)   ACTION="activate" ;;
  --deactivate) ACTION="deactivate" ;;
  --native-memory)
    ACTION="native"
    case "${2:-}" in
      on)  NATIVE_WANT="True" ;;
      off) NATIVE_WANT="False" ;;
      *)   fail "--native-memory needs 'on' or 'off'" ;;
    esac
    ;;
  "")           ACTION="copy" ;;
  *)            fail "Unknown arg: $1 (use --activate / --deactivate / --native-memory on|off / none)" ;;
esac

# ── 1. Copy the plugin dir into the overlay ────────────────────────────────
note "Copying provider plugin → $DEST"
docker exec -u sandbox "$CONTAINER" mkdir -p "$DEST_PARENT"
# Remove stale copy so deletions in the repo propagate, then copy fresh.
docker exec -u sandbox "$CONTAINER" rm -rf "$DEST"
docker cp "$SRC" "$CONTAINER:$DEST"
docker exec "$CONTAINER" chown -R sandbox:sandbox "$DEST"
info "Plugin copied. condition_label = $(grep -E '^condition_label:' "$SRC/condition.yaml" | head -1 | cut -d: -f2- | tr -d ' \"')"

# ── 2. Ensure telemetry dir exists (0700, owned sandbox) ───────────────────
docker exec -u sandbox "$CONTAINER" mkdir -p /sandbox/.hermes/telemetry
docker exec -u sandbox "$CONTAINER" chmod 700 /sandbox/.hermes/telemetry
info "Telemetry dir ready: /sandbox/.hermes/telemetry (0700)"

# ── 3. Optionally flip memory.provider in config.yaml ──────────────────────
set_provider() {
  local want="$1"  # "falda" or ""
  docker exec -u sandbox "$CONTAINER" cp "$CONFIG" "${CONFIG}.bak-pre-falda-$(date -u +%Y%m%dT%H%M%SZ)"
  # Use the venv python — it has PyYAML; the bare /usr/bin/python3.13 does not.
  # NOTE: -i is REQUIRED so the heredoc reaches python's stdin; without it
  # `python -` reads empty stdin, does nothing, and exits 0 (silent no-op).
  docker exec -i -u sandbox -e WANT="$want" "$CONTAINER" /opt/hermes/.venv/bin/python - "$CONFIG" <<'PYEOF'
import os, sys, yaml
path = sys.argv[1]
want = os.environ.get("WANT", "")
with open(path, encoding="utf-8-sig") as f:
    data = yaml.safe_load(f) or {}
data.setdefault("memory", {})
data["memory"]["provider"] = want
with open(path, "w", encoding="utf-8") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
print(f"memory.provider set to {want!r}")
PYEOF
}

set_native_memory() {
  local want="$1"  # "True" or "False"
  docker exec -u sandbox "$CONTAINER" cp "$CONFIG" "${CONFIG}.bak-pre-nativemem-$(date -u +%Y%m%dT%H%M%SZ)"
  docker exec -i -u sandbox -e WANT="$want" "$CONTAINER" /opt/hermes/.venv/bin/python - "$CONFIG" <<'PYEOF'
import os, sys, yaml
path = sys.argv[1]
want = os.environ["WANT"] == "True"
with open(path, encoding="utf-8-sig") as f:
    data = yaml.safe_load(f) or {}
mem = data.setdefault("memory", {})
mem["memory_enabled"] = want
mem["user_profile_enabled"] = want
with open(path, "w", encoding="utf-8") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
print(f"memory_enabled={want} user_profile_enabled={want} "
      f"(provider={mem.get('provider','')!r} — unchanged)")
PYEOF
}

case "$ACTION" in
  native)
    note "Setting native Hermes memory (MEMORY.md + USER.md) -> $NATIVE_WANT"
    set_native_memory "$NATIVE_WANT"
    info "Done. The FALDA provider setting was not touched."
    warn "RESTART REQUIRED: restart the Hermes gateway for this to take effect."
    ;;
  activate)
    note "Activating: memory.provider = falda"
    set_provider "falda"
    info "Activated."
    warn "RESTART REQUIRED: restart the Hermes gateway to load the provider."
    warn "  Verify after restart: docker exec -u sandbox $CONTAINER hermes memory status"
    ;;
  deactivate)
    note "Deactivating: memory.provider = ''"
    set_provider ""
    info "Deactivated."
    warn "RESTART REQUIRED: restart the Hermes gateway for this to take effect."
    ;;
  copy)
    note "Plugin copied only (config.yaml untouched)."
    note "To activate: bash ops/apply-memory-provider.sh --activate, then restart the gateway."
    ;;
esac

info "Done."
