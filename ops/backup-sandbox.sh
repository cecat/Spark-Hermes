#!/usr/bin/env bash
# backup-sandbox.sh — a COMPLETE, verified backup of Gandalf's sandbox state.
#
#   bash ops/backup-sandbox.sh              # full backup incl. state.db
#   bash ops/backup-sandbox.sh --no-statedb # skip the 1.2 GB db (much faster)
#
# Run from your shell: every step reaches into the live sandbox.
#
# Why this exists: ops/snapshot.sh aborts on state.db (1.2 GB) and takes the
# whole run down with it, so it has been silently producing empty backups —
# v18 and v20 hold nothing but a manifest and SOUL.md. This is the working
# replacement. Read-only; the live sandbox is never modified.
#
# What it protects against: NOT loss of conversation history — that lives in
# state.db and in FALDA, and survives a rebuild anyway. The real exposure is
# the sandbox's writable layer, which a rebuild wipes. Restoring that by hand
# means re-applying plugins, skills, policies, Google deps and re-pairing
# devices: hours of fiddly work with plenty of room for a subtle mistake.
#
# Coverage is driven by the rebuild manifest itself (14 state dirs + SOUL.md +
# state.db) rather than a hand-kept list here, so it cannot drift from what a
# rebuild actually restores.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
ensure_path

WANT_STATEDB=1
[ "${1:-}" = "--no-statedb" ] && WANT_STATEDB=0

CONTAINER=$(gandalf_container)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HOME/gandalf-backup-$STAMP"
mkdir -p "$OUT"
SBX=/sandbox/.hermes

# The 14 dirs from the rebuild manifest. Keep in sync with:
#   ~/.nemoclaw/rebuild-backups/gandalf/*/rebuild-manifest.json
STATE_DIRS="memories sessions skills plugins cron logs skins plans workspace profiles cache pairing platforms weixin"

note "Container: $CONTAINER"
note "Output:    $OUT"
[ "$WANT_STATEDB" -eq 1 ] || warn "Skipping state.db (--no-statedb)"

FAILED=""
EMPTY=""

# ── 1. State directories ───────────────────────────────────────────────────
# Per-directory download is the mechanism verified to work; it is only the
# 1.2 GB state.db that defeats the CLI's transfer.
note "Downloading ${STATE_DIRS// /, }"
for d in $STATE_DIRS; do
    printf '  %-12s ' "$d"
    if timeout 180 openshell sandbox download gandalf "$SBX/$d" "$OUT/$d" >/dev/null 2>&1; then
        n=$(find "$OUT/$d" -type f 2>/dev/null | wc -l)
        sz=$(du -sh "$OUT/$d" 2>/dev/null | cut -f1)
        if [ "$n" -eq 0 ]; then
            echo "empty"
            EMPTY="$EMPTY $d"
        else
            echo "$n files, $sz"
        fi
    else
        echo "FAILED"
        FAILED="$FAILED $d"
    fi
done

# ── 2. Loose state files ───────────────────────────────────────────────────
note "Downloading SOUL.md and runtime config"
for f in SOUL.md config.yaml runtime/gateway_state.json runtime/channel_directory.json; do
    printf '  %-32s ' "$f"
    mkdir -p "$OUT/$(dirname "$f")"
    if docker exec -u sandbox "$CONTAINER" cat "$SBX/$f" > "$OUT/$f" 2>/dev/null \
       && [ -s "$OUT/$f" ]; then
        echo "$(wc -c < "$OUT/$f") bytes"
    else
        echo "MISSING"
        rm -f "$OUT/$f"
        FAILED="$FAILED $f"
    fi
done

# ── 3. NemoClaw's own registry ─────────────────────────────────────────────
# Lives on the HOST, not in the sandbox: custom policies, credential hashes,
# messaging config, the openshellDriver field. It has NO schema version, so a
# newer CLI cannot tell it is reading an old format — copy it before any
# upgrade. Tiny, and the one thing a sandbox-side backup would miss.
note "Copying the host-side NemoClaw registry"
mkdir -p "$OUT/nemoclaw-host"
cp -a ~/.nemoclaw/sandboxes.json "$OUT/nemoclaw-host/" 2>/dev/null \
    && info "sandboxes.json ($(wc -c < ~/.nemoclaw/sandboxes.json) bytes)" \
    || { warn "could not copy sandboxes.json"; FAILED="$FAILED sandboxes.json"; }
cp -a ~/.nemoclaw/onboard-session.json "$OUT/nemoclaw-host/" 2>/dev/null || true

# ── 4. state.db ────────────────────────────────────────────────────────────
# VACUUM INTO gives a consistent copy with the WAL folded in, without stopping
# the gateway; docker cp streams it out with none of the size ceiling that
# makes `openshell sandbox download` time out on this file.
if [ "$WANT_STATEDB" -eq 1 ]; then
    note "Archiving state.db (VACUUM INTO + gzip; takes a minute)"
    if docker exec -i -u sandbox "$CONTAINER" python3 - <<'PYEOF' 2>&1 | tail -1
import sqlite3, os
SRC = "/sandbox/.hermes/runtime/state.db"
DST = "/tmp/state-backup.db"
if os.path.exists(DST):
    os.remove(DST)
con = sqlite3.connect(f"file:{SRC}?mode=ro", uri=True)
con.execute("VACUUM INTO ?", (DST,))
con.close()
print(f"  copied {os.path.getsize(DST)/1e9:.2f} GB")
PYEOF
    then
        docker exec -u sandbox "$CONTAINER" gzip -f -6 /tmp/state-backup.db 2>/dev/null
        if docker cp "$CONTAINER:/tmp/state-backup.db.gz" "$OUT/state.db.gz" 2>/dev/null; then
            info "state.db.gz ($(du -h "$OUT/state.db.gz" | cut -f1))"
        else
            warn "docker cp of state.db failed"
            FAILED="$FAILED state.db"
        fi
        docker exec -u sandbox "$CONTAINER" rm -f /tmp/state-backup.db.gz 2>/dev/null || true
    else
        warn "VACUUM INTO failed"
        FAILED="$FAILED state.db"
    fi
fi

# ── 5. Verify ──────────────────────────────────────────────────────────────
# An unverified backup is a hope. snapshot.sh reported success over an empty
# directory for three weeks precisely because nobody opened the result.
note "Verifying"
if [ -f "$OUT/state.db.gz" ]; then
    gzip -t "$OUT/state.db.gz" 2>/dev/null \
        && info "state.db.gz passes integrity check" \
        || { warn "state.db.gz FAILED integrity check"; FAILED="$FAILED state.db-verify"; }
fi
python3 -c "import json,sys; json.load(open('$OUT/nemoclaw-host/sandboxes.json')); print('  sandboxes.json parses')" 2>/dev/null \
    || warn "sandboxes.json did not parse"

{
    echo "Gandalf sandbox backup — $STAMP"
    echo "container: $CONTAINER"
    echo "state.db included: $([ "$WANT_STATEDB" -eq 1 ] && echo yes || echo no)"
    echo
    echo "Restore notes:"
    echo "  state.db:   gunzip -c state.db.gz > state.db, then upload to $SBX/runtime/"
    echo "  state dirs: openshell sandbox upload gandalf <local> $SBX/<dir>"
    echo "  registry:   cp nemoclaw-host/sandboxes.json ~/.nemoclaw/"
    echo "  Much of this is also reproducible from Spark-Hermes:"
    echo "    ops/apply-skills.sh  ops/apply-cron.sh  ops/apply-policies.sh"
    echo "    ops/apply-memory-provider.sh  ops/apply-soul.sh  ops/post-rebuild.sh"
    echo "  Not reproducible from the repo — these are why this backup exists:"
    echo "    pairing/ (device + channel pairing)  profiles/  memories/  sessions/"
    echo
    echo "empty dirs (normal for unused features): ${EMPTY:-none}"
    echo "FAILED:                                  ${FAILED:-none}"
} | tee "$OUT/MANIFEST.txt"

echo
du -sh "$OUT"
if [ -n "$FAILED" ]; then
    warn "Some items failed:$FAILED"
    warn "This backup is INCOMPLETE — do not treat it as a rollback point."
    exit 1
fi
info "Backup complete and verified: $OUT"
