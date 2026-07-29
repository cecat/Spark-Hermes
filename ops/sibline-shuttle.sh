#!/usr/bin/env bash
# Sibline sandbox shuttle — Gandalf (Hermes).
#
# The host-side sibline bridge (spark-fabric services/sibline-bridge, agent
# gandalf) speaks NATS and stages messages in HOST files under ~/.sibline/:
#   inbound : ~/.sibline/mailbox-gandalf.jsonl      (append-only, bridge writes)
#   outbound: ~/.sibline/outbox-gandalf/*.json      (bridge reads + publishes)
#
# Gandalf's /sandbox/.hermes has NO host bind-mount (overlay only), so this
# shuttle moves messages across the boundary via `docker exec`, mirroring
# ops/outbox-processor.sh. Two directions each tick:
#   INBOUND : append NEW lines of the host mailbox into the sandbox inbox
#             /sandbox/.hermes/sibline/inbox.jsonl (offset-tracked; no dupes).
#   OUTBOUND: pull *.json the agent dropped in /sandbox/.hermes/sibline/outbox/
#             out to ~/.sibline/outbox-gandalf/ for the bridge to publish, then
#             remove them from the sandbox.
#
# Runs on the host as a --user service (loop). Idempotent + restart-safe.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

CONTAINER=$(gandalf_container)
HOST_MAILBOX="$HOME/.sibline/mailbox-gandalf.jsonl"
HOST_OUTBOX="$HOME/.sibline/outbox-gandalf"
SANDBOX_DIR="/sandbox/.hermes/sibline"
SANDBOX_INBOX="$SANDBOX_DIR/inbox.jsonl"
SANDBOX_OUTBOX="$SANDBOX_DIR/outbox"
OFFSET_FILE="$HOME/.sibline/shuttle-gandalf.offset"   # lines of HOST_MAILBOX already shuttled
POLL_S="${SIBLINE_SHUTTLE_POLL_S:-3}"

mkdir -p "$HOST_OUTBOX"
touch "$HOST_MAILBOX"
[ -f "$OFFSET_FILE" ] || echo 0 > "$OFFSET_FILE"

# Ensure the sandbox-side tree exists (sandbox-owned).
docker exec -u sandbox "$CONTAINER" sh -c "mkdir -p '$SANDBOX_OUTBOX' && touch '$SANDBOX_INBOX'" \
  || fail "could not init sandbox sibline tree"

log() { printf '%s [shuttle-gandalf] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

sync_inbound() {
  local total off new
  total=$(wc -l < "$HOST_MAILBOX" 2>/dev/null || echo 0)
  off=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
  [ "$total" -gt "$off" ] || return 0
  new=$((total - off))
  # Take the new lines and append them into the sandbox inbox in one exec.
  # tail -n +N is 1-based; +$((off+1)) yields lines after the offset.
  tail -n "+$((off + 1))" "$HOST_MAILBOX" \
    | docker exec -i -u sandbox "$CONTAINER" sh -c "cat >> '$SANDBOX_INBOX'" \
    && echo "$total" > "$OFFSET_FILE" \
    && log "inbound: +$new line(s) -> $SANDBOX_INBOX (offset=$total)"
}

sync_outbound() {
  # List agent-dropped outbound files, move each to the host outbox, remove in sandbox.
  local files
  files=$(docker exec -u sandbox "$CONTAINER" sh -c "ls -1 '$SANDBOX_OUTBOX'/*.json 2>/dev/null" || true)
  [ -n "$files" ] || return 0
  for path in $files; do
    local base; base=$(basename "$path")
    # Copy content out, then delete from sandbox (only after a successful write).
    if docker exec -u sandbox "$CONTAINER" sh -c "cat '$path'" > "$HOST_OUTBOX/.tmp-$base" 2>/dev/null; then
      mv "$HOST_OUTBOX/.tmp-$base" "$HOST_OUTBOX/$base"
      docker exec -u sandbox "$CONTAINER" sh -c "rm -f '$path'"
      log "outbound: $base -> $HOST_OUTBOX/ (bridge will publish)"
    else
      rm -f "$HOST_OUTBOX/.tmp-$base"
      log "outbound: FAILED to read $base; leaving in sandbox for retry"
    fi
  done
}

log "starting: mailbox=$HOST_MAILBOX sandbox=$SANDBOX_DIR poll=${POLL_S}s"
while :; do
  sync_inbound || log "inbound sync error"
  sync_outbound || log "outbound sync error"
  sleep "$POLL_S"
done
