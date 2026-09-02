#!/usr/bin/env bash
# PATH guard for the GLOBAL `nemoclaw` binary (NemoClaw v0.0.55, Gandalf's).
#
# Install this AS `nemoclaw` on PATH. It inspects argv + environment and either
# refuses loudly or delegates, unchanged, to the real CLI.
#
# WHY THIS EXISTS
#
# The global `nemoclaw` is hardcoded to ONE control plane: GATEWAY_NAME is the
# constant "nemoclaw", re-stamped into OPENSHELL_GATEWAY 12x in dist/lib/onboard.js,
# and REGISTRY_FILE is a single $HOME/.nemoclaw/sandboxes.json with no per-port
# state root. Aimed at a secondary plane it does not fail — dist/lib/
# gateway-runtime-action.js classifies the foreign plane as `connected_other`
# and calls startGatewayForRecovery(), relaunching a gateway there with v0.0.55
# defaults: plaintext where the sandbox requires mTLS, and Gandalf's database.
# It also rewrites Gandalf's own gateway entry in place.
#
# `nemoclaw luoji policy-list` did exactly that on 2026-09-01 and produced a
# 93-restart loop. The verb was read-only. The damage comes from the binary
# starting up at all, so there is no safe subcommand — the only fix is to not
# let the process reach main().
#
# DESIGN: fail closed. Anything not provably aimed at gandalf/:8080 is refused.
# A false refusal costs five seconds; a false permit costs a restart loop.
#
# The correct tool for a secondary plane is ops/nmc.sh (v0.0.108 sidecar with
# NEMOCLAW_GATEWAY_PORT set and ambient gateway selection scrubbed).
set -uo pipefail

GUARD_VERSION=1
NVM_BIN="$HOME/.nvm/versions/node/v22.22.3/bin"
NODE_BIN="$NVM_BIN/node"

# Delegate to the real entry point by ABSOLUTE PATH, never by PATH lookup and
# never via the nvm bin symlink — either of those can resolve back to this
# guard once it is installed at both interposition points, and recurse.
REAL_JS=""
for cand in \
    "$HOME/.nvm/versions/node/v22.22.3/lib/node_modules/nemoclaw/bin/nemoclaw.js" \
    "$HOME/gandalf-bringup/nemoclaw-src/bin/nemoclaw.js"
do
    [ -f "$cand" ] && { REAL_JS="$cand"; break; }
done

SAFE_PLANE_PORT=8080
SAFE_GATEWAY_NAME="nemoclaw"
SAFE_SANDBOX="gandalf"

# Global (non-sandbox-scoped) verbs, from dist/commands/ in the v0.0.55 tree.
# `onboard` is deliberately NOT here — see the onboard refusal below.
GLOBAL_TOKENS="backup-all credentials debug deploy gc inference internal list \
resources root sandbox setup setup-spark start status stop tunnel uninstall \
update upgrade-sandboxes help --help -h --version -v"

refuse() {
    local reason="$1" advice="$2"
    {
        echo
        echo "REFUSED by nemoclaw-guard: $reason"
        echo
        echo "  The global 'nemoclaw' is v0.0.55 and is hardcoded to the :8080"
        echo "  (gandalf) control plane. Aimed anywhere else it relaunches a"
        echo "  gateway there with plaintext auth and gandalf's database."
        echo "  A read-only-sounding verb is NOT safe: 'nemoclaw luoji"
        echo "  policy-list' caused a 93-restart loop on 2026-09-01."
        echo
        echo "  Use instead:"
        echo "    $advice"
        echo
        echo "  If you are certain this is correct, re-run with:"
        echo "    NEMOCLAW_GUARD_BYPASS=i-understand nemoclaw ${ARGS[*]:-}"
        echo
    } >&2
    # Audit the refusal. log_event previously fired only on the bypass and
    # allow paths, so the log filled with verdict=allow while every refusal —
    # the security-relevant event — was dropped silently, making an unaudited
    # guard look healthy. log_event is defined below but resolves at call
    # time, and ends in `|| true`, so an unwritable log cannot change this exit.
    log_event refuse "$reason"
    exit 92
}

# Best-effort audit trail. Never let logging failure change the outcome.
log_event() {
    local verdict="$1"; shift
    { printf '%s guard=v%s verdict=%s argv=%s\n' \
        "$(date -Is 2>/dev/null || echo unknown-time)" \
        "$GUARD_VERSION" "$verdict" "$*"
    } >>"$HOME/.nemoclaw-guard.log" 2>/dev/null || true
}

ARGS=("$@")

if [ "${NEMOCLAW_GUARD_BYPASS:-}" = "i-understand" ]; then
    echo "nemoclaw-guard: BYPASSED by NEMOCLAW_GUARD_BYPASS. You own the outcome." >&2
    log_event bypass ${ARGS[@]+"${ARGS[@]}"}
else
    # ---- 1. Environment must be provably gandalf's plane, or unset. --------
    # Checked BEFORE any argv allowance, including --help: a tainted env makes
    # every invocation ambiguous regardless of the verb.
    if [ -n "${NEMOCLAW_GATEWAY_PORT:-}" ] && [ "${NEMOCLAW_GATEWAY_PORT}" != "$SAFE_PLANE_PORT" ]; then
        refuse "NEMOCLAW_GATEWAY_PORT=${NEMOCLAW_GATEWAY_PORT} targets a non-gandalf plane." \
               "bash ops/nmc.sh <agent> ${ARGS[*]:-<command>}"
    fi
    if [ -n "${OPENSHELL_GATEWAY:-}" ] && [ "${OPENSHELL_GATEWAY}" != "$SAFE_GATEWAY_NAME" ]; then
        refuse "OPENSHELL_GATEWAY=${OPENSHELL_GATEWAY} selects a non-gandalf gateway. \
You are probably in a shell that sourced ops/cecat-env.sh or ops/luoji-env.sh." \
               "bash ops/nmc.sh <agent> ${ARGS[*]:-<command>}"
    fi
    if [ -n "${OPENSHELL_GATEWAY_ENDPOINT:-}" ]; then
        refuse "OPENSHELL_GATEWAY_ENDPOINT is set; the target plane is ambiguous." \
               "env -u OPENSHELL_GATEWAY_ENDPOINT nemoclaw ${ARGS[*]:-<command>}"
    fi

    # ---- 2. No argument may name or imply a secondary plane. --------------
    for a in ${ARGS[@]+"${ARGS[@]}"}; do
        low="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
        if printf '%s' "$low" | grep -Eq '(^|[^a-z0-9])(cecat|luoji)([^a-z0-9]|$)'; then
            hit="$(printf '%s' "$low" | grep -Eo '(cecat|luoji)' | head -1)"
            # Drop a leading bare agent name so the advice doesn't read
            # "nmc.sh cecat cecat ..." — nmc.sh takes the agent itself.
            rest=("${ARGS[@]}")
            [ "${rest[0]:-}" = "$hit" ] && rest=("${rest[@]:1}")
            refuse "argument '$a' names secondary-plane agent '$hit'." \
                   "bash ops/nmc.sh $hit ${rest[*]:-<command>}"
        fi
        if printf '%s' "$low" | grep -Eq '(^|[^0-9])(8090|8091)([^0-9]|$)'; then
            refuse "argument '$a' references a secondary-plane port (8090/8091)." \
                   "bash ops/nmc.sh <agent> ${ARGS[*]:-<command>}"
        fi
    done

    # ---- 3. onboard is refused outright on this version. ------------------
    # v0.0.55 has one shared registry and one shared inference route, so a
    # second onboard silently re-points gandalf's model traffic (PR #6711 /
    # #6338 land in v0.0.108). New agents get their own plane via ops/nmc.sh.
    if [ "${ARGS[0]:-}" = "onboard" ]; then
        refuse "'onboard' on v0.0.55 shares gandalf's registry and inference route; \
a second sandbox silently re-points his model traffic." \
               "bash ops/nmc.sh <agent> onboard ...   # v0.0.108 sidecar, per-port state"
    fi

    # ---- 4. First positional must be a known global verb, or gandalf. -----
    # Fail closed: an unrecognised leading token is an unknown sandbox name,
    # which is exactly the shape of the 2026-09-01 incident.
    first="${ARGS[0]:-}"
    if [ -n "$first" ] && [ "$first" != "$SAFE_SANDBOX" ]; then
        known=no
        for t in $GLOBAL_TOKENS; do
            [ "$first" = "$t" ] && { known=yes; break; }
        done
        if [ "$known" = no ]; then
            refuse "'$first' is not a known global command and is not '$SAFE_SANDBOX'; \
treating it as an unrecognised sandbox name." \
                   "bash ops/nmc.sh $first ${ARGS[*]:1}"
        fi
    fi

    log_event allow ${ARGS[@]+"${ARGS[@]}"}
fi

# ---- Delegate, unchanged. ------------------------------------------------
if [ -z "$REAL_JS" ]; then
    echo "nemoclaw-guard: cannot locate the real nemoclaw entry point." >&2
    echo "  looked for bin/nemoclaw.js under the nvm global module and" >&2
    echo "  \$HOME/gandalf-bringup/nemoclaw-src. Guard is installed but the" >&2
    echo "  CLI behind it is missing — do NOT reinstall over this file." >&2
    exit 93
fi
[ -x "$NODE_BIN" ] || { echo "nemoclaw-guard: node not found at $NODE_BIN" >&2; exit 93; }

export PATH="$NVM_BIN:$PATH"
exec "$NODE_BIN" "$REAL_JS" ${ARGS[@]+"${ARGS[@]}"}
