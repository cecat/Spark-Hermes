#!/usr/bin/env bash
# fix-agent-paths.sh — restore the filesystem contract the runbooks expect.
#
#   bash ops/fix-agent-paths.sh --check     # report only (default)
#   bash ops/fix-agent-paths.sh --commit    # apply
#   bash ops/fix-agent-paths.sh --revert    # undo
#
# ── WHY ─────────────────────────────────────────────────────────────────────
#
# On the legacy stack three bind mounts WERE the agents' filesystem contract:
#
#   spark-ai-agents/cecat          -> /workspace   rw
#   spark-ai-agents/shared         -> /shared      rw
#   spark-ai-agents/cecat/scripts  -> /scripts     ro
#
# Host cron wrote $BASE/cecat/TODO.md and the agent read /workspace/TODO.md —
# the SAME INODE. No sync, no drift. That contract appears in no config file,
# which is exactly why it was never migrated. OpenShell sandboxes have no bind
# mounts, so the contract was silently deleted and 10 of 12 runbooks now
# reference paths that do not exist.
#
# The heartbeat has been firing correctly every 15 minutes the whole time,
# burning three model calls per tick reasoning over dead paths.
#
# ── SCOPE: RUNBOOK_GMAIL_TRIAGE ONLY ────────────────────────────────────────
#
# Charlie 2026-09-05: "If you can get the email triage runbook to function then
# there is some hope... If not then there is no point in wasting time and tokens
# on the other 11."
#
# So this fixes exactly what that runbook needs, verified by enumerating it:
#
#   8x /scripts/gmail-api.py                     MISSING -> installed here
#   6x /workspace/memory/heartbeat-state.json    exists, wrong path -> symlink
#   1x /workspace/runbooks/_ON_FAILURE.md        exists, wrong path -> symlink
#   1x /scripts/contacts-api.py                  MISSING -> installed here
#   1x /shared/slack/outbox/                     see NOTE below
#
# ── /scripts IS NOT EMPTY — do not symlink over it ──────────────────────────
#
# The image ships /scripts with generate-openclaw-config.mts and lib/ (npm
# remediation tooling). Replacing that directory could break image tooling. So
# this ADDS the two api scripts into it rather than replacing it. Additive and
# reversible.
#
# ── NOTE: /shared/slack/outbox is NOT created here ──────────────────────────
#
# That is the approval gate, and whether it is recreated or replaced by the
# native Slack adapter is Charlie's decision, not a path fix. The triage runbook
# uses it only in its final "post a summary" step; the triage work itself —
# read, classify, label, archive — needs none of it. If the run completes and
# only the Slack post fails, that is a PASS for this test and the gate decision
# can be taken calmly afterwards.
set -u

MODE="${1:---check}"
case "$MODE" in
  --check) ACT=check ;; --commit) ACT=commit ;; --revert) ACT=revert ;;
  *) echo "Usage: $0 [--check|--commit|--revert]" >&2; exit 1 ;;
esac

RC=0
for AGENT in cecat luoji; do
    echo "════════════════════════════════════════════"
    echo "  $AGENT"
    echo "════════════════════════════════════════════"

    CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
    if [ -z "$CON" ]; then echo "  NO SANDBOX — skipped"; RC=1; continue; fi

    WS=/sandbox/.openclaw/workspace

    case "$ACT" in
    check)
        docker exec -u sandbox "$CON" sh -c '
        for p in /workspace /scripts/gmail-api.py /scripts/contacts-api.py \
                 /workspace/TODO.md /workspace/memory/heartbeat-state.json \
                 /workspace/runbooks/_ON_FAILURE.md /shared; do
            printf "  %-48s " "$p"
            if [ -e "$p" ]; then echo "OK"; else echo "MISSING"; fi
        done'
        ;;
    commit)
        # 1. /workspace -> the real workspace. Content is already correct; only
        #    the path is wrong. Symlink verified working in-sandbox beforehand.
        docker exec -u root "$CON" ln -sfn "$WS" /workspace \
            && echo "  /workspace -> $WS"

        # 2. The two api scripts the runbook shells out to. Copied INTO the
        #    existing /scripts, never over it. These are the wrapper versions
        #    that pin credential paths — copying the .real.py would bypass that
        #    and break auth, so the plain names are deliberate.
        for s in gmail-api.py contacts-api.py; do
            if docker exec -u sandbox "$CON" test -f "$WS/scripts/$s"; then
                docker exec -u root "$CON" sh -c "cp '$WS/scripts/$s' '/scripts/$s' && chmod 755 '/scripts/$s'" \
                    && echo "  /scripts/$s installed"
            else
                echo "  !! $WS/scripts/$s not found — triage will fail"; RC=1
            fi
        done

        # 3. Prove it from the agent's own point of view, not ours.
        echo "  --- verify as the agent sees it ---"
        docker exec -u sandbox "$CON" sh -c '
        for p in /workspace/TODO.md /workspace/memory/heartbeat-state.json \
                 /workspace/runbooks/RUNBOOK_GMAIL_TRIAGE.md /scripts/gmail-api.py; do
            printf "    %-56s " "$p"; test -e "$p" && echo OK || echo MISSING
        done'
        ;;
    revert)
        docker exec -u root "$CON" sh -c 'rm -f /workspace /scripts/gmail-api.py /scripts/contacts-api.py' \
            && echo "  reverted (symlink + 2 copied scripts removed)"
        ;;
    esac
    echo
done

if [ "$ACT" = commit ]; then
cat <<'EOM'
════════════════════════════════════════════
  NOT DONE YET — the paths are the prerequisite, not the proof
════════════════════════════════════════════
  These paths live in the container's WRITABLE LAYER and are wiped on rebuild.
  This script must be re-run by the deploy hook, like the credential pushes.

  The real test is one heartbeat tick. Wait ~15 min, then:

    C=$(docker ps --format '{{.Names}}' | grep '^openshell-default--cecat-')
    docker exec -u sandbox $C tail -40 /tmp/gateway.log

  Ticks appear as: agents/tool-policy -> tool-search -> model-fetch.
  NOTE the gateway writes its OWN log at /tmp/gateway.log inside the sandbox —
  `docker logs` does NOT show ticks. Looking in the wrong file is what produced
  a false "the heartbeat is dead" diagnosis on 2026-09-04.

  PASS  = the inbox is actually triaged (messages read/labelled/archived).
  PARTIAL = triage happens, only the Slack summary fails on /shared — expected,
            that is the gate decision, not a path bug.
  FAIL  = still nothing. Capture the tick's output before changing anything.
EOM
fi
exit $RC
