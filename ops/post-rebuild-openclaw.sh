#!/usr/bin/env bash
# post-rebuild-openclaw.sh — restore everything an OpenShell REBUILD silently
# deletes for the OpenClaw agents (cecat, luoji).
#
#   bash ops/post-rebuild-openclaw.sh --check     # report only (default)
#   bash ops/post-rebuild-openclaw.sh --commit    # restore, then prove it
#
# ── THIS IS NOT ops/post-rebuild.sh ─────────────────────────────────────────
#
# ops/post-rebuild.sh is GANDALF-ONLY (Hermes pylibs, Google OAuth, Hermes cron,
# OpenShell presets). This is its OpenClaw counterpart and is deliberately a
# SEPARATE FILE. Doctrine C-2 / GOALS.md: OpenClaw and Hermes share a substrate,
# but dependency between the GATEWAYS is categorically forbidden — the test is
# "if gateway X vanishes, does gateway Y notice?" Folding OpenClaw restoration
# into Gandalf's script would mean deleting Hermes breaks OpenClaw. Two scripts
# is a reality constraint, not duplication to be cleaned up later.
#
# ── WHAT DIES, AND ON WHAT EVENT ────────────────────────────────────────────
#
#   sshfs mounts (host <-> sandbox)          die on REBOOT
#   /shared and /workspace symlinks          die on REBUILD (writable layer)
#   OOM wrapper patch                        die on REBUILD (writable layer)
#   /scripts repoint in in-sandbox runbooks  die on REBUILD (if not in backup)
#   PAUSE sentinels in /sandbox/shared/state die on REBOOT *and* REBUILD
#
# ALL FIVE FAIL SILENTLY. The agents keep answering Slack while every runbook
# goes inert — that exact failure hid for four weeks once
# (Claude-Code-Supervisor/runbook/POSTMORTEM-the-mounts.md) and has recurred
# three times since. Hence: this script proves each item at the layer that owns
# it and exits NON-ZERO if any check fails. A restore script that reports
# success without proof is worse than none — it converts an outage into a
# CONFIDENT outage.
#
# ── ORDERING, AND WHY IT IS NOT THE OBVIOUS ONE ─────────────────────────────
#
#   1. mounts + symlinks    — everything downstream addresses paths that do not
#                             resolve until these exist. /sandbox/shared is
#                             created here, and step 2 writes into it.
#   2. PAUSE sentinels      — MOVED AHEAD OF THE OOM PATCH ON PURPOSE. Step 4
#                             restarts the gateway, and a restarted gateway
#                             resumes heartbeats. If a paused agent's sentinel
#                             is not in place first, its very next tick runs
#                             UNPAUSED. The kill switch already fails open
#                             (see push-pause-sentinels.sh); do not hand it a
#                             race as well.
#   3. /scripts repoint     — file edits only, no gateway involvement. Must
#                             land before the restart so the agent comes back to
#                             runbooks whose paths resolve.
#   4. OOM wrapper patch    — LAST mutating step, because it is the only one
#                             that restarts the gateway. Restart-last means the
#                             agent wakes into a fully restored filesystem.
#   5. verification pass    — re-checks all four from scratch. Not a summary of
#                             what the steps *claimed*; an independent re-read.
#
# `ops/reset-sessions-openshell.sh` is deliberately NOT called: that is cron's
# job and is not rebuild-related.
#
# `ops/fix-agent-paths.sh --commit` is deliberately NOT called either. It copies
# the api wrappers INTO the root-owned /scripts, which is precisely what
# repoint-scripts-to-workspace.sh removed: mode 755 and readable via docker
# exec, but EACCES from the agent's own hardened exec context. Re-installing
# them would resurrect a failure that took three wrong diagnoses to find.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) DO=0 ;; --commit) DO=1 ;;
  *) echo "Usage: $0 [--check|--commit]" >&2; exit 2 ;;
esac

REPO="$HOME/code/Spark-Hermes"
HOST_STATE="$HOME/code/spark-ai-agents/shared/state"
PLANES="cecat:8090 luoji:8091"

RC=0
PASS=0
FAILED=0
CHANGED=0

ok()   { printf '  \033[0;32mOK  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1" >&2; FAILED=$((FAILED+1)); RC=1; }
note() { printf '  \033[0;36mi   \033[0m %s\n' "$1"; }
hdr()  { printf '\n════════════════════════════════════════════\n  %s\n════════════════════════════════════════════\n' "$1"; }

mnt_of()  { printf '%s/.nemoclaw/gateways/%s/mounts/%s' "$HOME" "$2" "$1"; }
ws_of()   { printf '%s/.openclaw/workspace' "$(mnt_of "$1" "$2")"; }
con_of()  { docker ps --format '{{.Names}}' | grep "^openshell-default--${1}-" | head -1; }

# ── preflight ───────────────────────────────────────────────────────────────
hdr "Preflight"
for pair in $PLANES; do
    A="${pair%%:*}"
    C=$(con_of "$A")
    if [ -n "$C" ]; then ok "$A sandbox running"; else bad "$A: NO RUNNING SANDBOX — start it first (bash ops/agent-planes.sh start)"; fi
done
if [ "$FAILED" -gt 0 ]; then
    echo
    echo "Preflight failed. Nothing was changed." >&2
    exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. MOUNTS + SYMLINKS
# ════════════════════════════════════════════════════════════════════════════
hdr "1/4  sshfs mounts + in-sandbox symlinks"

NEED_MOUNT=0
for pair in $PLANES; do
    A="${pair%%:*}"; P="${pair##*:}"
    mountpoint -q "$(mnt_of "$A" "$P")" 2>/dev/null || NEED_MOUNT=1
done
# The symlinks die on rebuild even when the host-side mount is still up, so a
# mounted-looking host is NOT evidence the sandbox half survived. Check both.
for pair in $PLANES; do
    A="${pair%%:*}"
    C=$(con_of "$A")
    L=$(docker exec -u sandbox "$C" sh -c 'readlink /shared; readlink /workspace' 2>/dev/null | tr '\n' ' ')
    case "$L" in
      *"/sandbox/shared"*"/sandbox/.openclaw/workspace"*) : ;;
      *) NEED_MOUNT=1 ;;
    esac
done

if [ "$NEED_MOUNT" = 0 ]; then
    note "mounts and symlinks already in place — no action"
elif [ "$DO" = 0 ]; then
    note "WOULD run: bash ops/mount-agent-filespaces.sh --mount"
else
    bash "$REPO/ops/mount-agent-filespaces.sh" --mount || note "mount script returned non-zero; verification below decides"
    CHANGED=$((CHANGED+1))
fi

# ════════════════════════════════════════════════════════════════════════════
# 2. PAUSE SENTINELS  (before the gateway restart — see ordering note)
# ════════════════════════════════════════════════════════════════════════════
hdr "2/4  PAUSE sentinels"

# Only ever MIRROR host state inward. Never create a sentinel here: inventing a
# pause is as wrong as dropping one.
SENTINELS=""
[ -f "$HOST_STATE/PAUSE.global" ] && SENTINELS="$SENTINELS PAUSE.global"
for pair in $PLANES; do
    A="${pair%%:*}"
    [ -f "$HOST_STATE/PAUSE.agent.$A" ] && SENTINELS="$SENTINELS PAUSE.agent.$A"
done

if [ ! -d "$HOST_STATE" ]; then
    bad "host state dir missing: $HOST_STATE — cannot tell paused from unpaused"
elif [ -z "$SENTINELS" ]; then
    note "no host-side sentinel — agents are NOT paused, nothing to re-push"
elif [ "$DO" = 0 ]; then
    note "WOULD run: bash ops/push-pause-sentinels.sh   (host sentinels:$SENTINELS)"
else
    note "host sentinels:$SENTINELS"
    bash "$REPO/ops/push-pause-sentinels.sh" || note "push script returned non-zero; verification below decides"
    CHANGED=$((CHANGED+1))
fi

# ════════════════════════════════════════════════════════════════════════════
# 3. /scripts REPOINT
# ════════════════════════════════════════════════════════════════════════════
hdr "3/4  runbook script paths (/scripts -> /workspace/scripts)"

STALE_TOTAL=0
for pair in $PLANES; do
    A="${pair%%:*}"; P="${pair##*:}"
    W=$(ws_of "$A" "$P")
    if [ ! -d "$W" ]; then
        bad "$A: workspace not readable at $W — step 1 did not take"
        continue
    fi
    # shellcheck disable=SC2086
    N=$(grep -rl 'python3 /scripts/' "$W"/runbooks/*.md "$W"/TOOLS.md "$W"/PATHS.md 2>/dev/null | wc -l)
    STALE_TOTAL=$((STALE_TOTAL + N))
    note "$A: $N file(s) still reference /scripts/"
done

if [ "$STALE_TOTAL" = 0 ]; then
    note "no stale references — no action"
elif [ "$DO" = 0 ]; then
    note "WOULD run: bash ops/repoint-scripts-to-workspace.sh --commit"
else
    bash "$REPO/ops/repoint-scripts-to-workspace.sh" --commit || note "repoint returned non-zero; verification below decides"
    CHANGED=$((CHANGED+1))
fi

# ════════════════════════════════════════════════════════════════════════════
# 4. OOM WRAPPER PATCH  (restarts the gateway — must be last)
# ════════════════════════════════════════════════════════════════════════════
hdr "4/4  OOM wrapper patch"

OOMF=/usr/local/lib/nemoclaw/openclaw-runtime/node_modules/openclaw/dist/linux-oom-score-eO5nXmjv.js

# Count the unpatched marker. NO `|| echo 0` HERE — that idiom is wrong and is
# live in ops/patch-oom-wrapper.sh today: `grep -c` prints "0" AND exits 1 when
# there are no matches, so `grep -c ... || echo 0` yields the two-line string
# "0\n0", which fails every `= "0"` comparison. The result is a check that
# reports UNPATCHED on an agent that is correctly patched. `head -1` gives the
# real count; EMPTY output means the file was unreadable, which is a distinct
# failure and must not be silently coerced to 0.
oom_unpatched() { # oom_unpatched <container> -> count, or "" if unreadable
    docker exec -u sandbox "$1" sh -c \
        "grep -c 'oom_score_adj 2>/dev/null; exec' $OOMF 2>/dev/null" | head -1
}

NEED_OOM=0
for pair in $PLANES; do
    A="${pair%%:*}"
    C=$(con_of "$A")
    n=$(oom_unpatched "$C")
    if [ -z "$n" ]; then
        bad "$A: cannot read $OOMF — runtime file absent or unreadable"
    elif [ "$n" = "0" ]; then
        note "$A: 0 unpatched occurrence(s)"
    else
        note "$A: $n unpatched occurrence(s)"
        NEED_OOM=1
    fi
done

if [ "$NEED_OOM" = 0 ]; then
    note "already patched on both agents — no action, gateway NOT restarted"
elif [ "$DO" = 0 ]; then
    note "WOULD run: bash ops/patch-oom-wrapper.sh --commit   (restarts both gateways)"
else
    bash "$REPO/ops/patch-oom-wrapper.sh" --commit || note "patch returned non-zero; verification below decides"
    CHANGED=$((CHANGED+1))
fi

# ════════════════════════════════════════════════════════════════════════════
# 5. VERIFICATION — independent re-read, not a summary of the above
# ════════════════════════════════════════════════════════════════════════════
hdr "VERIFICATION"

for pair in $PLANES; do
    A="${pair%%:*}"; P="${pair##*:}"
    M=$(mnt_of "$A" "$P"); W=$(ws_of "$A" "$P")
    C=$(con_of "$A")
    printf '\n  ── %s ──\n' "$A"

    # 1a. HOST layer owns the sshfs mount. mountpoint(1) alone is not enough —
    #     a dead sshfs transport endpoint still satisfies it — so read through
    #     it, under a timeout so a hung endpoint fails instead of hanging.
    if ! mountpoint -q "$M" 2>/dev/null; then
        bad "$A mount: not mounted at $M"
    else
        WSN=$(timeout 15 ls -1 "$W" 2>/dev/null | wc -l)
        if [ "$WSN" -lt 1 ]; then
            bad "$A mount: mounted but workspace unreadable/empty (entries=$WSN)"
        else
            ok "$A mount: readable, workspace entries=$WSN"
        fi
    fi

    # 1b. SANDBOX layer owns the symlinks. Assert the exact targets — a
    #     dangling or wrongly-aimed symlink passes a bare -e test.
    SL=$(docker exec -u sandbox "$C" readlink /shared 2>/dev/null || true)
    WL=$(docker exec -u sandbox "$C" readlink /workspace 2>/dev/null || true)
    [ "$SL" = /sandbox/shared ] \
        && ok "$A symlink: /shared -> $SL" \
        || bad "$A symlink: /shared -> '${SL:-<absent>}' (want /sandbox/shared)"
    [ "$WL" = /sandbox/.openclaw/workspace ] \
        && ok "$A symlink: /workspace -> $WL" \
        || bad "$A symlink: /workspace -> '${WL:-<absent>}' (want /sandbox/.openclaw/workspace)"

    # 1c. The symlinks resolving is not the same as the content being there.
    docker exec -u sandbox "$C" test -d /shared/state \
        && ok "$A path: /shared/state resolves" \
        || bad "$A path: /shared/state does not resolve through the symlink"
    docker exec -u sandbox "$C" test -f /workspace/TODO.md \
        && ok "$A path: /workspace/TODO.md resolves" \
        || bad "$A path: /workspace/TODO.md does not resolve through the symlink"

    # 2. PAUSE state must MATCH the host, in both directions. A sandbox that is
    #    missing a sentinel is an agent running while believed stopped; a
    #    sandbox holding a stale one is an agent stopped while believed running.
    WANT=""
    [ -f "$HOST_STATE/PAUSE.global" ] && WANT="PAUSE.global"
    [ -f "$HOST_STATE/PAUSE.agent.$A" ] && WANT="$WANT PAUSE.agent.$A"
    WANT=$(printf '%s' "$WANT" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')
    HAVE=$(docker exec -u sandbox "$C" sh -c 'ls /sandbox/shared/state 2>/dev/null' \
             | grep '^PAUSE\.' | sort | tr '\n' ' ' 2>/dev/null || true)
    if [ "$WANT" = "$HAVE" ]; then
        ok "$A pause: in sync [${WANT:-none}]"
    else
        bad "$A pause: host wants [${WANT:-none}] but sandbox has [${HAVE:-none}]"
    fi

    # 3. Runbook script paths. THE SCANNED COUNT IS PART OF THE ASSERTION.
    #    A check that reports "0 stale references" after scanning 0 files is the
    #    exact shape of the `PASS | sessions=0` bug that shipped on this box.
    #    Zero files scanned means the mount is gone, not that all is well.
    SCANNED=0; STALE=0
    for f in "$W"/runbooks/*.md "$W"/TOOLS.md "$W"/PATHS.md; do
        [ -f "$f" ] || continue
        SCANNED=$((SCANNED+1))
        grep -q 'python3 /scripts/' "$f" 2>/dev/null && STALE=$((STALE+1))
    done
    if [ "$SCANNED" -lt 1 ]; then
        bad "$A runbooks: scanned=0 — nothing to check means the mount is down, NOT that paths are clean"
    elif [ "$STALE" -gt 0 ]; then
        bad "$A runbooks: scanned=$SCANNED stale=$STALE still reference /scripts/"
    else
        ok "$A runbooks: scanned=$SCANNED stale=0"
    fi

    # 3b. Repointed paths are worthless if the target is absent. Resolve every
    #     referenced basename and require the real file, sandbox-owned.
    REFS=$(grep -rhoE '/workspace/scripts/[A-Za-z0-9_.-]+' \
             "$W"/runbooks/*.md "$W"/TOOLS.md "$W"/PATHS.md 2>/dev/null \
             | sed 's|.*/||' | sort -u)
    if [ -z "$REFS" ]; then
        note "$A scripts: no /workspace/scripts/ references in runbooks"
    else
        for b in $REFS; do
            if [ ! -f "$W/scripts/$b" ]; then
                bad "$A scripts: runbooks call $b but /workspace/scripts/$b is absent"
            else
                OWN=$(docker exec -u sandbox "$C" stat -c '%U:%a' "/sandbox/.openclaw/workspace/scripts/$b" 2>/dev/null || echo "?")
                case "$OWN" in
                  sandbox:*) ok "$A scripts: $b present ($OWN)" ;;
                  *)         bad "$A scripts: $b present but owned $OWN — agent exec will EACCES (want sandbox:*)" ;;
                esac
            fi
        done
    fi

    # 4. OOM patch. Assert the marker is gone AND the file still parses AND a
    #    gateway is alive — a patch that leaves the runtime unparseable looks
    #    identical to a patch that worked, until the next respawn.
    LEFT=$(oom_unpatched "$C")
    if [ -z "$LEFT" ]; then
        bad "$A oom: could not read $OOMF (empty result is a BUG, not a pass)"
    elif [ "$LEFT" = "0" ]; then
        ok "$A oom: prologue absent"
    else
        bad "$A oom: $LEFT unpatched occurrence(s) — every agent exec will fail"
    fi
    if docker exec -u sandbox "$C" sh -c "node --check $OOMF >/dev/null 2>&1"; then
        ok "$A oom: runtime file parses (node --check)"
    else
        bad "$A oom: node --check FAILED on $OOMF — gateway will not respawn"
    fi
    GP=$(docker exec -u sandbox "$C" sh -c 'pgrep -f openclaw-gateway | head -1' 2>/dev/null || true)
    [ -n "$GP" ] && ok "$A gateway: running (pid $GP)" || bad "$A gateway: NOT RUNNING"
done

# ── result ──────────────────────────────────────────────────────────────────
hdr "RESULT"
if [ "$DO" = 0 ]; then
    printf '  MODE: --check (nothing was changed)\n'
else
    printf '  MODE: --commit  restore steps that acted: %d of 4\n' "$CHANGED"
    [ "$CHANGED" = 0 ] && printf '  NO-OP: every item was already in place. Nothing was restored.\n'
fi
printf '  checks passed: %d   failed: %d\n' "$PASS" "$FAILED"

if [ "$RC" != 0 ]; then
    printf '\n  \033[0;31mFAILED — %d check(s) did not pass. The agents are NOT restored.\033[0m\n' "$FAILED" >&2
    printf '  Do not treat Slack replies as evidence of health: the agents answer Slack\n' >&2
    printf '  perfectly well with every runbook inert. That is the failure mode.\n' >&2
fi

cat <<'EOM'

════════════════════════════════════════════
  WHAT THESE CHECKS DO **NOT** PROVE
════════════════════════════════════════════
  Every check above runs through `docker exec`, which BYPASSES the agent's own
  hardened exec context (seccomp, NoNewPrivs=1, empty capability bounding set).
  That asymmetry has produced at least three false passes on this box: a file
  readable via `docker exec -u sandbox` still returned EACCES to the agent.

  So the checks above prove the RESTORE LANDED. They do not prove the agent can
  USE it. Only one thing does — the agent running a runbook:

    C=$(docker ps --format '{{.Names}}' | grep '^openshell-default--cecat-')
    docker exec -u sandbox $C bash /shared/scripts/lib/with-file-lock.sh \
      /workspace/TODO.md "READY | $(date -u +%Y-%m-%dT%H:%M:%SZ) | PLAN: /workspace/runbooks/RUNBOOK_GMAIL_TRIAGE.md"

  Wait one heartbeat (<=15 min), then:

    docker exec -u sandbox $C sh -c 'tail -3 /workspace/TODO.md'

  COMPLETED = the chain works. A NEW error = progress. The gateway writes its
  own log INSIDE the sandbox at /tmp/gateway.log — `docker logs` does NOT show
  heartbeat ticks, and looking in the wrong file produced a false "the heartbeat
  is dead" diagnosis on 2026-09-04.
EOM

exit $RC
