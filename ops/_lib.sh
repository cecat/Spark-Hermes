# Shared helpers for ops/*.sh. Source with:  . "$(dirname "$0")/_lib.sh"
# (Not executable on its own.)

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
note()  { printf "${CYAN}[i]${NC} %s\n" "$*"; }

# Locate the gandalf sandbox container; fail if missing.
gandalf_container() {
  local name
  name=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^openshell-gandalf-' | head -1)
  [ -n "$name" ] || fail "No gandalf sandbox container is running (docker ps shows nothing matching ^openshell-gandalf-)."
  printf "%s" "$name"
}

# Ensure ~/.local/bin is on PATH so nemohermes/openshell resolve.
ensure_path() {
  case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
}

# Source ~/.hermes/.env if present (best-effort).
load_hermes_env() {
  [ -f ~/.hermes/.env ] && { set -a; . ~/.hermes/.env; set +a; } || true
}

# Path to the deployment-specific config (identifiers, not secrets).
HERMES_CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"

# Require ~/.hermes/config.yaml to exist, with no placeholder values left over
# from bringup/config.example.yaml. Apply scripts call this before doing anything.
require_hermes_config() {
  [ -f "$HERMES_CONFIG" ] || fail "Missing $HERMES_CONFIG — copy bringup/config.example.yaml to it, fill in your real values, then re-run."
  if grep -qE '<YOUR_|<your-|REPLACE_ME' "$HERMES_CONFIG"; then
    fail "$HERMES_CONFIG still has placeholder values (look for <YOUR_*> / <your-*> / REPLACE_ME). Fill them in first."
  fi
}

# Read a value from ~/.hermes/config.yaml by dotted key (e.g. "slack.home_channel_id").
# For arrays / nested objects, returns YAML. Uses Python yaml since we don't have yq.
hermes_cfg() {
  local key="$1"
  [ -f "$HERMES_CONFIG" ] || fail "Missing $HERMES_CONFIG"
  python3 - "$HERMES_CONFIG" "$key" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    if data is None: sys.exit(0)
    data = data.get(k) if isinstance(data, dict) else None
if data is None: sys.exit(0)
if isinstance(data, (str, int, float, bool)):
    print(data)
else:
    import json; print(json.dumps(data))
PYEOF
}

# Run a command inside the sandbox as user `sandbox` with HERMES_HOME set.
sb_exec() {
  local container; container=$(gandalf_container)
  docker exec -u sandbox \
    -e HERMES_HOME=/sandbox/.hermes \
    -e PYTHONPATH=/sandbox/.hermes/pylibs \
    "$container" "$@"
}

# Repo root (the parent dir of ops/).
repo_root() {
  cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd
}
