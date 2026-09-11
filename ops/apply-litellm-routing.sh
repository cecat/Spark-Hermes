#!/usr/bin/env bash
# apply-litellm-routing.sh — route cecat and luoji inference through LiteLLM so
# they inherit the Argo -> Qwen fallback that Gandalf already has.
#
#   bash ops/apply-litellm-routing.sh            # --check (default)
#   bash ops/apply-litellm-routing.sh --commit   # patch config (does NOT restart)
#   bash ops/apply-litellm-routing.sh --revert   # restore the pre-change backup
#
# ── THE GAP ─────────────────────────────────────────────────────────────────
#
#   Gandalf     -> LiteLLM :4000 -> argo-shim -> Argo   --fallback--> vLLM Qwen
#   distillers  -> LiteLLM :4000 -> same                --fallback--> vLLM Qwen
#   cecat/luoji -> inference.local -----------------------> Argo   (NO fallback)
#
# Both OpenClaw configs contain **zero** `fallback` keys and one provider. When
# Argo is down — Duo re-auth, tunnel drop — Gandalf degrades to local Qwen and
# keeps working; cecat and luoji just fail. `litellm/config.yaml:101-105`
# already lists `claudesonnet46` and `claudeopus47` in the fallback chain, so
# both agents' models are covered the moment they route through it.
#
# This is OpenClaw adopting a mechanism Hermes already proves, not a new one.
#
# ── DOCTRINE (C-2) — this does NOT couple the gateways ──────────────────────
#
# LiteLLM is **substrate**. `spark-litellm.service` was renamed from
# `gandalf-litellm.service` on 2026-09-03 exactly because the gateway-name
# prefix misdescribed ownership — and that rename was prompted by a real
# incident where Spark-Hermes/ops/shutdown.sh stopped a service an OpenClaw
# tenant depended on. The test is "if Hermes vanishes, does OpenClaw notice?":
# LiteLLM, argo-shim and vLLM all keep running. It does not.
#
# ── WHAT CHANGES, AND WHAT DELIBERATELY DOES NOT ────────────────────────────
#
# Adds a `litellm` provider **alongside** the existing `inference` provider and
# points `agents.defaults.model.primary` at it. `inference` is left in place
# untouched: --revert is then a one-key flip, and the old route stays available.
#
# Model ids are unchanged (`claudesonnet46` for cecat, `claudeopus47` for
# luoji) — LiteLLM exposes those exact `model_name`s, so nothing else moves.
#
# `http://`, not `https://`: LiteLLM terminates no TLS (same as FALDA on :8077).
#
# ── PREREQUISITE ────────────────────────────────────────────────────────────
#
# The egress preset must be applied first or the L7 proxy returns 403 and the
# agent cannot reach :4000 at all. This script CHECKS for the bridge and refuses
# to --commit without it; it cannot check the preset (that needs `nmc.sh`, which
# flips the global default gateway — C-12), so it prints the command instead.
#
# ── TIMEOUT NOTE ────────────────────────────────────────────────────────────
#
# `litellm/config.yaml` `request_timeout` was raised 120 -> 600 on 2026-09-10 to
# match `agents.defaults.timeoutSeconds` on every consumer. At 120s a
# slow-but-working Argo call was cancelled and answered by Qwen instead — a
# silent quality downgrade dressed as resilience. **If that setting gets
# reverted, this routing change becomes actively harmful.**
#
# ── C-0b ────────────────────────────────────────────────────────────────────
# --commit overwrites a live config. Backs up first; --revert restores. Does NOT
# restart the gateway.
set -uo pipefail

MODE="${1:---check}"
case "$MODE" in
    --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
    *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RC=0

# ── Prerequisite: the socat bridge ──────────────────────────────────────────
if ss -ltn 2>/dev/null | grep -q '172\.19\.0\.1:4000'; then
    echo "  prereq OK   : litellm bridge listening on 172.19.0.1:4000"
else
    echo "  prereq FAIL : NO listener on 172.19.0.1:4000 — sandboxes cannot reach LiteLLM."
    echo "                systemctl --user status spark-litellm-bridge.service"
    [ "$ACT" = commit ] && { echo "REFUSING to --commit without the bridge." >&2; exit 1; }
fi
echo "  prereq NOTE : egress preset must be applied per agent FIRST (additive, restarts nothing):"
echo "                bash ops/nmc.sh cecat policy add --from-file bringup/50-openshell-policies/litellm-egress.yaml --yes"
echo "                bash ops/nmc.sh luoji policy add --from-file bringup/50-openshell-policies/litellm-egress.yaml --yes"
echo

for pair in "cecat:8090:claudesonnet46" "luoji:8091:claudeopus47"; do
    AGENT="${pair%%:*}"; REST="${pair#*:}"; PORT="${REST%%:*}"; MODEL="${REST##*:}"
    OC="$HOME/.nemoclaw/gateways/$PORT/mounts/$AGENT/.openclaw"
    CFG="$OC/openclaw.json"

    echo "════════════════════════════════════════════"
    echo "  $AGENT (plane $PORT, model $MODEL)"
    echo "════════════════════════════════════════════"
    [ -f "$CFG" ] || { echo "  FAIL: $CFG unreachable (mount down?)"; RC=1; continue; }

    if [ "$ACT" = revert ]; then
        BK="$(ls -t "$OC"/openclaw.json.pre-litellm-* 2>/dev/null | head -1)"
        [ -z "$BK" ] && { echo "  FAIL: no pre-litellm backup"; RC=1; continue; }
        cp "$BK" "$CFG" && echo "  REVERTED from $(basename "$BK")" || { echo "  FAIL"; RC=1; }
        continue
    fi

    OUT="$(python3 - "$CFG" "$MODEL" <<'PY'
import json, sys
cfg, model = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(cfg))
except Exception as e:
    print("PARSE_FAIL %s" % e); raise SystemExit(0)

provs = ((d.get("models") or {}).get("providers"))
if not isinstance(provs, dict) or "inference" not in provs:
    print("NO_INFERENCE_PROVIDER"); raise SystemExit(0)

# Mirror the live inference model entry so contextWindow/maxTokens/compat stay
# identical — only the transport changes. Guessing these would be a silent
# behaviour change.
src = None
for m in (provs["inference"].get("models") or []):
    if m.get("id") == model:
        src = json.loads(json.dumps(m)); break
if src is None:
    print("MODEL_NOT_FOUND %s" % model); raise SystemExit(0)
src["name"] = "litellm/%s" % model

want = {
    "baseUrl": "http://host.openshell.internal:4000/v1",
    "apiKey": "unused",
    "api": "openai-completions",
    "timeoutSeconds": 600,
    "models": [src],
}
cur_primary = ((d.get("agents") or {}).get("defaults") or {}).get("model", {}).get("primary")
if provs.get("litellm") == want and cur_primary == "litellm/%s" % model:
    print("ALREADY"); raise SystemExit(0)

provs["litellm"] = want                       # `inference` left intact for rollback
d["agents"]["defaults"]["model"]["primary"] = "litellm/%s" % model
print("PATCH %s" % cur_primary)
print(json.dumps(d, indent=2))
PY
)"
    STATUS="$(printf '%s\n' "$OUT" | head -1)"
    case "$STATUS" in
        PARSE_FAIL*|NO_INFERENCE_PROVIDER|MODEL_NOT_FOUND*)
            echo "  FAIL: $STATUS"; RC=1; continue ;;
        ALREADY) echo "  already routed through litellm — no change"; continue ;;
    esac

    echo "  provider   : + litellm (http://host.openshell.internal:4000/v1, 600s)"
    echo "  primary    : ${STATUS#PATCH } -> litellm/$MODEL"
    echo "  inference  : left in place for rollback"

    if [ "$ACT" = check ]; then echo "  --check only. Nothing changed."; continue; fi

    cp "$CFG" "$OC/openclaw.json.pre-litellm-$STAMP" || { echo "  FAIL: backup"; RC=1; continue; }
    echo "  BACKUP     : openclaw.json.pre-litellm-$STAMP"
    TMP="$CFG.tmp-litellm-$STAMP"
    printf '%s\n' "$OUT" | tail -n +2 > "$TMP"
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null; then
        echo "  FAIL: patched JSON does not parse — original untouched"; rm -f "$TMP"; RC=1; continue
    fi
    cat "$TMP" > "$CFG" && rm -f "$TMP" && echo "  PATCHED" || { echo "  FAIL: write"; RC=1; }
done

if [ "$ACT" = commit ] && [ "$RC" -eq 0 ]; then
    cat <<'EOF'

  Restart to pick it up:
      bash ops/restart-openclaw-gateways.sh

  ── VERIFY — a restart proves nothing on its own ────────────────────────────
  1. The agent still answers at all (a 403 from the L7 proxy looks like a dead
     agent). Watch a heartbeat land:
       tail -5 ~/.nemoclaw/gateways/8090/mounts/cecat/.openclaw/logs/gateway-persistent.log
  2. Traffic is actually going to LiteLLM, not inference.local:
       grep -o 'url=http[^ ]*' <that log> | sort -u | tail -3
     Expect host.openshell.internal:4000. If it still says inference.local the
     config did not take.
  3. THE REAL TEST — the fallback fires. Not verifiable without stopping Argo,
     which is disruptive. Do it deliberately, not by accident:
       pkill -f 'argo-shim --port 44497'   # then watch an agent still answer
     Re-auth costs an interactive Duo prompt — see spark-ai/shutdown.sh Step 5.
EOF
fi
exit "$RC"
