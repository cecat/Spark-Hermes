#!/usr/bin/env bash
# Sync an OpenClaw agent workspace between git and its OpenShell sandbox.
#
#   bash ops/apply-agent-workspace.sh <agent> --status         # compare, change nothing (default)
#   bash ops/apply-agent-workspace.sh <agent> --push [--dry-run]
#   bash ops/apply-agent-workspace.sh <agent> --backup-memory
#
# <agent> is cecat or luoji.
#
# ── The three-way split this script exists to respect ────────────────────────
#
# An agent workspace is NOT one thing. Treating it as one is how the earlier
# migration silently dropped 64 of cecat's 103 files.
#
#   1. CONFIG      — git-tracked, human-authored: SOUL.md, IDENTITY.md,
#                    runbooks/, PATHS.md. Git is the source of truth.
#                    --push sends these, and ONLY these.
#
#   2. MEMORY      — agent-written: memory/*.md. `.gitignore:1` is `**/memory/`,
#                    so this has NEVER been in git, deliberately: it carries
#                    inbox metadata — names, addresses, message IDs (same reason
#                    `**/scratch/` is excluded). The LIVE copy is authoritative.
#                    --push never touches it. --backup-memory archives it.
#
#   3. RUNTIME     — heartbeat-state.json, sessions, .openclaw/. Written
#                    continuously by whichever agent is running. Never synced in
#                    either direction; a copy is a lie the moment it lands.
#
# ── Why --push does not use `openshell sandbox upload` ───────────────────────
#
# That command applies .gitignore filtering by default, which silently dropped
# all of memory/ during the migration. Passing --no-git-ignore fixes THAT bug
# but creates the opposite one: it would then push runtime state over the live
# agent's own files. `docker cp` of an explicit, git-derived file list is the
# only approach that cannot do either.
#
# ── Direction of travel ──────────────────────────────────────────────────────
#
# UNTIL CUTOVER the old `openclaw-sbx-agent-<agent>-*` container is the live
# agent and its bind-mounted host directory is authoritative for memory. The
# OpenShell sandbox is a staging copy. AFTER CUTOVER that reverses. This script
# never guesses: --push is always git→sandbox, --backup-memory is always
# sandbox→host archive.

set -euo pipefail
. "$(dirname "$0")/_lib.sh"

REPO_AGENTS="$HOME/code/spark-ai-agents"
ARCHIVE_ROOT="$HOME/.agent-memory-backups"
SANDBOX_WS="/sandbox/.openclaw/workspace"

# NemoClaw generates POLICY.md inside the sandbox; it has no git counterpart and
# must survive a push. workspace-state.json is runtime bookkeeping.
declare -a SANDBOX_OWNED=("POLICY.md" ".openclaw/workspace-state.json")

AGENT="${1:-}"
MODE="--status"
DRY_RUN=0
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --status|--push|--backup-memory) MODE="$1" ;;
        --dry-run) DRY_RUN=1 ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

case "$AGENT" in
    cecat|luoji) ;;
    "") fail "usage: $0 <cecat|luoji> [--status|--push|--backup-memory] [--dry-run]" ;;
    *) fail "unknown agent '$AGENT' (expected cecat or luoji)" ;;
esac

SRC="$REPO_AGENTS/$AGENT"
[ -d "$SRC" ] || fail "no workspace at $SRC"

CON=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^openshell-default--${AGENT}-" | head -1 || true)
[ -n "$CON" ] || fail "no running OpenShell sandbox for '$AGENT' (looked for ^openshell-default--${AGENT}-). Start it: bash ops/agent-planes.sh start"

# Everything inside the sandbox runs as `sandbox`. A file created there by root
# is unopenable by the gateway's own user — that is what broke `memory index`
# on 2026-08-21. Never drop the -u.
sbx() { docker exec -u sandbox "$CON" "$@"; }

git_tracked() { git -C "$REPO_AGENTS" ls-files "$AGENT" | sed "s|^$AGENT/||"; }

# ── --status ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "--status" ]; then
    note "agent:     $AGENT"
    note "git:       $SRC"
    note "sandbox:   $CON:$SANDBOX_WS"
    echo ""

    n_tracked=$(git_tracked | wc -l)
    n_disk=$(find "$SRC" -type f -not -path '*/.git/*' | wc -l)
    n_sbx=$(sbx find "$SANDBOX_WS" -type f | wc -l)
    note "git-tracked (config): $n_tracked   on host disk: $n_disk   in sandbox: $n_sbx"
    echo ""

    echo "── config drift (git-tracked files only) ──"
    drift=0
    while IFS= read -r rel; do
        [ -f "$SRC/$rel" ] || { warn "missing on host: $rel"; drift=1; continue; }
        h_host=$(md5sum < "$SRC/$rel" | cut -d' ' -f1)
        h_sbx=$(sbx sh -c "md5sum < '$SANDBOX_WS/$rel' 2>/dev/null" | cut -d' ' -f1 || true)
        if [ -z "$h_sbx" ]; then
            warn "absent in sandbox: $rel"; drift=1
        elif [ "$h_host" != "$h_sbx" ]; then
            warn "DIFFERS: $rel"; drift=1
        fi
    done < <(git_tracked)
    [ "$drift" -eq 0 ] && info "all git-tracked config identical"
    echo ""

    echo "── memory (never pushed; live copy is authoritative) ──"
    m_host=$(find "$SRC/memory" -name '*.md' 2>/dev/null | wc -l)
    m_sbx=$(sbx sh -c "find '$SANDBOX_WS/memory' -name '*.md' 2>/dev/null | wc -l" || echo 0)
    note "memory files — host: $m_host   sandbox: $m_sbx"
    latest=$(ls -1d "$ARCHIVE_ROOT/$AGENT"/* 2>/dev/null | tail -1 || true)
    if [ -n "$latest" ]; then
        note "last backup: $latest ($(find "$latest" -type f | wc -l) files)"
    else
        warn "no memory backup yet — run: $0 $AGENT --backup-memory"
    fi
    exit 0
fi

# ── --backup-memory ──────────────────────────────────────────────────────────
if [ "$MODE" = "--backup-memory" ]; then
    # Deliberately OUTSIDE the git repo: memory is gitignored for privacy
    # reasons (inbox metadata), and a backup inside the tree invites someone to
    # `git add -f` it later.
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    DEST="$ARCHIVE_ROOT/$AGENT/$STAMP"

    if ! sbx test -d "$SANDBOX_WS/memory"; then
        warn "no memory/ directory in the sandbox — nothing to back up"
        exit 0
    fi

    mkdir -p "$DEST"
    chmod 700 "$ARCHIVE_ROOT" "$ARCHIVE_ROOT/$AGENT" "$DEST"
    docker cp "$CON:$SANDBOX_WS/memory/." "$DEST/" \
        || fail "docker cp failed"

    n=$(find "$DEST" -type f | wc -l)
    [ "$n" -gt 0 ] || { rmdir "$DEST" 2>/dev/null || true; fail "backup produced 0 files — refusing to record an empty archive"; }
    info "backed up $n memory file(s) → $DEST"
    note "mode 700; outside the git repo on purpose (memory is gitignored: inbox metadata)"
    exit 0
fi

# ── --push ───────────────────────────────────────────────────────────────────
# Refuse to push over the LIVE agent. Until cutover the old container serves
# real traffic, and pushing config under a running agent is how you get a
# half-old, half-new prompt on the next turn.
OLD_CON=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^openclaw-sbx-agent-${AGENT}-" | head -1 || true)
if [ -n "$OLD_CON" ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "the OLD stack container '$OLD_CON' is still running."
    warn "That is the live $AGENT. This push targets the STAGING sandbox ($CON) only,"
    warn "which is correct pre-cutover — but re-run with --dry-run first if unsure."
    echo ""
fi

n=0; changed=0
while IFS= read -r rel; do
    [ -f "$SRC/$rel" ] || { warn "skip (missing on host): $rel"; continue; }

    skip=0
    for owned in "${SANDBOX_OWNED[@]}"; do
        [ "$rel" = "$owned" ] && skip=1
    done
    [ "$skip" -eq 1 ] && { note "skip (sandbox-owned): $rel"; continue; }

    n=$((n + 1))
    h_host=$(md5sum < "$SRC/$rel" | cut -d' ' -f1)
    h_sbx=$(sbx sh -c "md5sum < '$SANDBOX_WS/$rel' 2>/dev/null" | cut -d' ' -f1 || true)
    [ "$h_host" = "$h_sbx" ] && continue

    changed=$((changed + 1))
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would push: %s\n' "$rel"
        continue
    fi

    sbx mkdir -p "$SANDBOX_WS/$(dirname "$rel")"
    docker cp "$SRC/$rel" "$CON:$SANDBOX_WS/$rel" || fail "docker cp failed for $rel"
    # docker cp preserves the HOST uid, so the file lands root-owned. Fix it or
    # the gateway (running as `sandbox`) cannot read its own config.
    docker exec -u root "$CON" chown sandbox:sandbox "$SANDBOX_WS/$rel"
    printf '  pushed: %s\n' "$rel"
done < <(git_tracked)

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    note "dry run — $changed of $n git-tracked file(s) would change. Nothing was written."
else
    info "pushed $changed of $n git-tracked file(s)"
    [ "$changed" -gt 0 ] && note "config reload is hot (gateway.reload.mode=hot); no restart needed"
fi
note "memory/ and runtime state were NOT touched, by design"
