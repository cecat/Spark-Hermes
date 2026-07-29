#!/usr/bin/env bash
# Drive the FALDA-provider ablation grid: for each condition, set condition.yaml,
# restart the gateway, run a fixed probe set through the api_server, and let the
# provider's telemetry record what reached the model. Phase 5c research.
#
# The grid: prefetch {on,off} x search_tool {on,off}. share_tool held off.
#
# Probes are recall questions whose answers were seeded into FALDA. A
# prefetch-ON cell should surface them automatically (telemetry shows
# per_source_counts + injected_chars, and the model answers); a prefetch-OFF
# cell should not inject them (model can only get them via the search TOOL, if
# that knob is on).
#
# Contamination guard: the api_server derives session_id = sha256(system_prompt +
# first_user_message). Identical probe text across cells would collide and load
# stale history. So each probe is prefixed with a per-cell tag, guaranteeing a
# fresh, empty-history session per (cell x probe).
#
# Reaches the api_server via nsenter into the gateway's network namespace — the
# gateway binds 127.0.0.1:18642 inside its own netns, unreachable from a plain
# docker exec shell.
#
# Read-only w.r.t. FALDA data (only reads via prefetch/search); writes only
# telemetry. Does NOT touch shared services.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

REPO=$(repo_root)
CONTAINER=$(gandalf_container)
COND="$REPO/gandalf/plugins/falda/condition.yaml"
PORT=18642
MODEL="claudeopus47"

# Probe set: label|question. Answers are seeded in FALDA.
PROBES=(
  "codeword|What is Luoji's project codeword? Answer in one word."
  "ticket|What is Gandalf's assigned diagnostic ticket number? Answer with just the number."
  "deploywindow|When is the shared deploy window? Answer briefly."
)

# Grid cells: label|prefetch|search_tool
CELLS=(
  "P0S0|false|false"
  "P1S0|true|false"
  "P0S1|false|true"
  "P1S1|true|true"
)

gw_pid() { docker exec "$CONTAINER" sh -c 'pgrep -f "hermes gateway run" | head -1'; }

set_condition() {
  local label="$1" prefetch="$2" search="$3"
  # Edit the repo condition.yaml in place (sed on the known keys), then apply.
  python3 - "$COND" "$label" "$prefetch" "$search" <<'PYEOF'
import sys, re
path, label, prefetch, search = sys.argv[1:5]
src = open(path).read()
src = re.sub(r'^condition_label:.*$', f'condition_label: "grid-{label}"', src, count=1, flags=re.M)
src = re.sub(r'^prefetch_enabled:.*$', f'prefetch_enabled: {prefetch}', src, count=1, flags=re.M)
src = re.sub(r'^search_tool_enabled:.*$', f'search_tool_enabled: {search}', src, count=1, flags=re.M)
open(path, "w").write(src)
print(f"condition.yaml -> grid-{label} (prefetch={prefetch}, search_tool={search})")
PYEOF
  bash "$REPO/ops/apply-memory-provider.sh" >/dev/null
}

restart_gateway() {
  note "restarting gateway (docker restart) ..."
  docker restart "$CONTAINER" >/dev/null
  # Wait for the gateway process, then for the api_server to answer /health
  # inside its netns.
  until docker exec "$CONTAINER" sh -c 'pgrep -f "hermes gateway run" >/dev/null' 2>/dev/null; do sleep 1; done
  local ok=""
  # Re-resolve the gw pid each poll (it changes across restarts) and be patient:
  # a cron job running during startup delays the api_server bind.
  for _ in $(seq 1 120); do
    local gw; gw=$(gw_pid)
    if [ -n "$gw" ] && docker exec "$CONTAINER" sh -c "nsenter -t $gw -n curl -s -m 3 http://127.0.0.1:$PORT/health 2>/dev/null | grep -q '\"status\": \"ok\"'"; then ok=1; break; fi
    sleep 2
  done
  [ -n "$ok" ] || fail "gateway api_server did not become healthy after restart"
  info "gateway healthy"
}

run_probe() {
  local cell="$1" label="$2" question="$3"
  local gw; gw=$(gw_pid)
  # Per-cell prefix guarantees a fresh derived session (no history contamination).
  local tagged="[grid:$cell:$label] $question"
  local payload
  payload=$(python3 - "$MODEL" "$tagged" <<'PYEOF'
import sys, json
print(json.dumps({"model": sys.argv[1],
                  "messages":[{"role":"user","content":sys.argv[2]}],
                  "stream": False}))
PYEOF
)
  local ans
  ans=$(docker exec -i "$CONTAINER" sh -c "nsenter -t $gw -n curl -s -m 120 http://127.0.0.1:$PORT/v1/chat/completions -H 'content-type: application/json' --data-binary @-" <<<"$payload" \
      | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"].replace(chr(10)," ")[:160])
except Exception as e:
    print("ERR:", e)')
  printf "    %-12s -> %s\n" "$label" "$ans"
}

echo "=== FALDA provider ablation grid ==="
for cell_spec in "${CELLS[@]}"; do
  IFS='|' read -r cell prefetch search <<<"$cell_spec"
  echo ""
  note "CELL $cell  (prefetch=$prefetch, search_tool=$search)"
  set_condition "$cell" "$prefetch" "$search"
  restart_gateway
  for probe in "${PROBES[@]}"; do
    IFS='|' read -r plabel pq <<<"$probe"
    run_probe "$cell" "$plabel" "$pq"
  done
done

echo ""
note "pulling telemetry to host ..."
bash "$REPO/ops/pull-telemetry.sh"
info "grid complete. Telemetry: ~/.falda/telemetry/falda_provider.jsonl (filter condition = grid-*)"
