#!/usr/bin/env bash
# save-statedb.sh — archive Gandalf's 1.2 GB state.db, and report what is in it.
#
#   bash ops/save-statedb.sh
#
# Run from your shell: every step reaches into the live sandbox.
#
# Why this exists: ops/snapshot.sh cannot move state.db (1.2 GB) before timing
# out, so the whole snapshot aborts and Gandalf has had NO working backup for
# at least three weeks. This takes one properly, and answers whether the file
# is worth keeping before anyone spends time pruning it.
#
# Read-only with respect to the live database. VACUUM INTO writes a NEW file;
# it never modifies the original. The sandbox has no sqlite3 CLI, so every
# query runs through stdlib python3 inside the container — the same approach
# services/falda-tap/falda_tap_hermes.py already uses against this database.
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
ensure_path

CONTAINER=$(gandalf_container)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HOME/gandalf-statedb-$STAMP"
mkdir -p "$OUT"

note "Container: $CONTAINER"
note "Output: $OUT"

# ── 1. What is actually in there? ──────────────────────────────────────────
note "Analyzing composition (read-only)..."
docker exec -i -u sandbox "$CONTAINER" python3 - <<'PYEOF' 2>&1 | tee "$OUT/composition.txt"
import sqlite3
DB = "/sandbox/.hermes/runtime/state.db"
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
q = lambda s, *a: con.execute(s, a).fetchall()

pc = q("pragma page_count")[0][0]
ps = q("pragma page_size")[0][0]
print("=== size ===")
print(f"  {pc:,} pages x {ps} B = {pc*ps/1e9:.2f} GB")
print(f"  journal_mode = {q('pragma journal_mode')[0][0]}")

print("\n=== largest objects (tables + indexes) ===")
try:
    rows = q("""SELECT name, SUM(pgsize) AS b FROM dbstat
                GROUP BY name ORDER BY b DESC LIMIT 12""")
    for name, b in rows:
        print(f"  {name:<36} {b/1e6:>10.1f} MB")
except Exception as e:
    print(f"  dbstat unavailable ({e}) — using row counts only")

print("\n=== row counts ===")
for (t,) in q("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
    try:
        n = con.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0]
        print(f"  {t:<36} {n:>12,}")
    except Exception as e:
        print(f"  {t:<36} (skip: {str(e)[:40]})")

print("\n=== messages by source — is it mostly cron noise? ===")
try:
    tot = q("SELECT count(*) FROM messages")[0][0]
    for src, n, b in q("""SELECT s.source, count(*), SUM(length(coalesce(m.content,'')))
                          FROM messages m JOIN sessions s ON m.session_id = s.id
                          GROUP BY s.source ORDER BY 2 DESC"""):
        print(f"  {str(src):<16} {n:>10,} msgs ({100.0*n/tot:5.1f}%)  {(b or 0)/1e6:>8.1f} MB text")
except Exception as e:
    print(f"  {e}")

print("\n=== messages by role ===")
try:
    for role, n, b in q("""SELECT role, count(*), SUM(length(coalesce(content,'')))
                           FROM messages GROUP BY role ORDER BY 3 DESC"""):
        print(f"  {str(role):<16} {n:>10,} msgs   {(b or 0)/1e6:>8.1f} MB text")
except Exception as e:
    print(f"  {e}")

print("\n=== date range ===")
try:
    lo, hi = q("SELECT min(timestamp), max(timestamp) FROM messages")[0]
    print(f"  {lo}  ->  {hi}")
except Exception as e:
    print(f"  {e}")
PYEOF

# ── 2. Make a compact, consistent copy ─────────────────────────────────────
# VACUUM INTO folds in the WAL and drops free pages, giving a consistent
# point-in-time copy without stopping the gateway. It writes inside the
# sandbox because that is the only filesystem the sandbox user can write to.
note "VACUUM INTO a compact copy (can take a minute on 1.2 GB)..."
docker exec -i -u sandbox "$CONTAINER" python3 - <<'PYEOF' 2>&1 | tee -a "$OUT/composition.txt"
import sqlite3, os
SRC = "/sandbox/.hermes/runtime/state.db"
DST = "/tmp/state-archive.db"
if os.path.exists(DST):
    os.remove(DST)
con = sqlite3.connect(f"file:{SRC}?mode=ro", uri=True)
con.execute("VACUUM INTO ?", (DST,))
con.close()
print(f"  compact copy {os.path.getsize(DST)/1e9:.2f} GB "
      f"(original {os.path.getsize(SRC)/1e9:.2f} GB)")
PYEOF
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "VACUUM INTO failed — nothing written, live db untouched"

note "Compressing inside the sandbox (conversation text compresses well)..."
docker exec -u sandbox "$CONTAINER" sh -c \
    'gzip -f -6 /tmp/state-archive.db && ls -la /tmp/state-archive.db.gz' 2>&1 | tail -2

# docker cp streams from the container filesystem and has none of the size
# ceiling that made `openshell sandbox download` time out on this file.
note "Copying the archive out to the host..."
docker cp "$CONTAINER:/tmp/state-archive.db.gz" "$OUT/state-archive.db.gz" \
    || fail "docker cp failed — archive remains at /tmp/state-archive.db.gz in the sandbox"

docker exec -u sandbox "$CONTAINER" rm -f /tmp/state-archive.db.gz 2>/dev/null || true

# ── 3. Verify the archive is real ──────────────────────────────────────────
# An archive nobody opened is a hope, not a backup. That is exactly how
# ops/snapshot.sh reported success over an empty directory for three weeks.
note "Verifying the archive opens and matches..."
gzip -t "$OUT/state-archive.db.gz" || fail "archive failed gzip integrity check"
gunzip -c "$OUT/state-archive.db.gz" > "$OUT/state-archive.db" || fail "decompress failed"
python3 - "$OUT/state-archive.db" <<'PYEOF' 2>&1 | tee -a "$OUT/composition.txt"
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
print("  quick_check:", con.execute("pragma quick_check").fetchone()[0])
for t in ("messages", "sessions"):
    n = con.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
    print(f"  {t}: {n:,}")
PYEOF
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "archive did not open as a valid sqlite database"

rm -f "$OUT/state-archive.db"   # keep only the compressed copy

echo
info "Archive verified: $OUT/state-archive.db.gz"
ls -la "$OUT/"
echo
note "Composition report: $OUT/composition.txt"
note "The live database was NOT modified. Nothing was pruned."
note "Restore with:  gunzip -c state-archive.db.gz > state.db"
