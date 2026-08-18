#!/usr/bin/env bash
# share-on.sh — turn cross-agent FALDA sharing back on for Gandalf.
#
#   bash ops/share-on.sh
#
# Needs to run from your shell (not an assistant session) because every step
# below reaches into the live sandbox, and that is gated.
#
# What it does, in order:
#   1. Diagnoses why `ops/snapshot.sh` captures nothing  (READ-ONLY)
#   2. Backs up the state it can actually reach          (READ-ONLY)
#   3. Copies the plugin in and restarts the gateway     (CHANGES THE AGENT)
#   4. Verifies shared-corpus starts taking writes
#
# Stops at the first failure. Steps 1-2 change nothing, so a stop before
# step 3 leaves the agent exactly as it was.
#
# Background: share_tool_enabled sat false as leftover ablation state, so
# falda_share was never registered and shared-corpus took no writes for 20
# days. gandalf/plugins/falda/condition.yaml is already fixed in git; this
# pushes it into the running sandbox.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
ensure_path

REPO=$(repo_root)
CONTAINER=$(gandalf_container)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HOME/share-on-$STAMP"
mkdir -p "$OUT"

note "Container: $CONTAINER"
note "Logs and backups: $OUT"

# ── 1. Why does snapshot.sh capture nothing? ───────────────────────────────
# ops/snapshot.sh reported "Failed directories: <all of them>" and "Failed
# files: runtime/state.db", yet still registered as v20. v18 (2026-07-29) is
# equally empty, so this has been silently broken for at least three weeks.
#
# Measured from outside the sandbox: single-file download works, directory
# download works, `state.db` download hangs until timeout. So the transport is
# fine and something about state.db specifically is stuck. The likely cause is
# a SQLite lock — sqlite_backup on a db held open by a live gateway — but
# confirming that needs to look inside, which is what this step does.
hdr_step() { printf "\n\033[1m──── %s ────\033[0m\n" "$*"; }

hdr_step "1. Diagnosing the snapshot failure (read-only)"
{
  echo "### runtime/ listing — is state.db huge, or WAL-locked?"
  docker exec -u sandbox "$CONTAINER" ls -la /sandbox/.hermes/runtime/ 2>&1
  echo
  echo "### open writers on state.db (a live gateway holding it explains the hang)"
  docker exec -u sandbox "$CONTAINER" sh -c 'command -v fuser >/dev/null && fuser -v /sandbox/.hermes/runtime/state.db 2>&1 || echo "fuser not present"' 2>&1
  echo
  echo "### integrity + WAL mode"
  docker exec -u sandbox "$CONTAINER" sh -c 'command -v sqlite3 >/dev/null && { sqlite3 /sandbox/.hermes/runtime/state.db "pragma quick_check; pragma journal_mode;" 2>&1; } || echo "sqlite3 not present in sandbox"' 2>&1
  echo
  echo "### do the three venv binaries from S1a exist? (open question from the pre-plan)"
  for p in /opt/hermes/.venv/bin/hermes /opt/hermes/.venv/bin/python3 /opt/hermes/.venv/bin/python3.13; do
    printf '%-42s ' "$p"
    docker exec "$CONTAINER" sh -c "[ -e $p ] && (readlink -f $p) || echo ABSENT" 2>&1
  done
  echo
  echo "### can the OpenClaw agents reach FALDA through the new nim_net bridge?"
  echo "### (expect 200; this is the half of shared memory that luoji/cecat need)"
  docker exec openclaw-gateway sh -c 'curl -sS -o /dev/null -w "  172.18.0.1:8077 -> %{http_code}\n" --max-time 10 -X POST http://172.18.0.1:8077/atoms/query -H "Content-Type: application/json" -d "{\"tenant\":\"luoji\",\"limit\":1}"' 2>&1
} 2>&1 | tee "$OUT/1-snapshot-diagnosis.log"

# ── 2. Back up what we can actually reach ──────────────────────────────────
# Since snapshot.sh produces nothing, take our own copy of the state that
# matters before touching the agent. Directory download is verified working.
hdr_step "2. Backing up reachable state (read-only)"
BACKUP_OK=1
for d in plugins memories workspace; do
  note "download: /sandbox/.hermes/$d"
  if ! timeout 120 openshell sandbox download gandalf "/sandbox/.hermes/$d" "$OUT/$d" 2>&1 | tail -2; then
    warn "could not download $d"
    BACKUP_OK=0
  fi
done
docker exec -u sandbox "$CONTAINER" cat /sandbox/.hermes/config.yaml > "$OUT/config.yaml" 2>/dev/null \
  && info "saved config.yaml" || { warn "could not save config.yaml"; BACKUP_OK=0; }

if [ "$BACKUP_OK" -ne 1 ]; then
  fail "Backup incomplete — stopping before changing anything. Inspect $OUT."
fi
info "Backup written to $OUT"

# ── 3. Apply the change (THIS TOUCHES THE RUNNING AGENT) ───────────────────
hdr_step "3. Applying the plugin + restarting the gateway"
warn "This restarts the Hermes gateway and drops in-flight sessions."
printf "Continue? [y/N] "
read -r reply
case "$reply" in
  [yY]*) ;;
  *) note "Stopped at your request. Nothing was changed."; exit 0 ;;
esac

note "Copying plugin (condition.yaml with share_tool_enabled: true)"
bash "$REPO/ops/apply-memory-provider.sh" 2>&1 | tee "$OUT/3-apply.log" || fail "apply-memory-provider.sh failed"

note "Restarting the Hermes gateway"
docker restart "$CONTAINER" 2>&1 | tee -a "$OUT/3-apply.log" || fail "restart failed"

note "Waiting for the sandbox to come back"
for i in $(seq 1 30); do
  sleep 4
  if openshell sandbox list 2>/dev/null | grep -q 'gandalf.*Ready'; then
    info "Sandbox Ready after ~$((i*4))s"; break
  fi
  [ "$i" -eq 30 ] && fail "Sandbox did not return to Ready within 120s — check: openshell sandbox list"
done

# ── 4. Verify ──────────────────────────────────────────────────────────────
hdr_step "4. Verifying"
{
  echo "### condition_label the plugin loaded with (expect steady-state-shared-on)"
  docker exec -u sandbox "$CONTAINER" grep -E '^condition_label:|^share_tool_enabled:|^search_tool_enabled:' \
    /sandbox/.hermes/plugins/falda/condition.yaml 2>&1
  echo
  echo "### hermes memory status"
  docker exec -u sandbox "$CONTAINER" hermes memory status 2>&1 | head -20
  echo
  echo "### shared-corpus size (baseline was 2 — it only grows once Gandalf calls falda_share)"
  curl -s -X POST http://127.0.0.1:8077/atoms/query -H 'content-type: application/json' \
    -d '{"tenant":"gandalf","pool":"shared-corpus","limit":3}' \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("total:", d.get("total"))' 2>&1
} 2>&1 | tee "$OUT/4-verify.log"

echo
info "Done. Full logs in $OUT"
note "shared-corpus grows when Gandalf next chooses to call falda_share — the"
note "tool is now registered, but writes are a deliberate act, not automatic."
note "Re-check later:  bash ops/status.sh   or the curl in 4-verify.log"
