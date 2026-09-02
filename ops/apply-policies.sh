#!/usr/bin/env bash
# Apply OpenShell egress presets from bringup/50-openshell-policies/ to ONE
# named agent's control plane.
#
#   bash ops/apply-policies.sh <agent> [--shared] [--dry-run]
#   bash ops/apply-policies.sh cecat --dry-run
#   bash ops/apply-policies.sh gandalf --shared
#
# Idempotent — re-applying a preset that's already loaded is a no-op
# (NemoClaw reports "Policy unchanged").
#
# WHY THE AGENT ARGUMENT IS MANDATORY
#
# This script used to glob every *.yaml in the policies dir and push each one to
# `nemohermes gandalf policy-add`, target hardcoded. That was correct while
# gandalf was the only agent. It stopped being correct the moment cecat and luoji
# dropped their own presets into the same directory: running it then loaded three
# foreign presets onto the one plane we are least willing to perturb.
#
# Egress presets key on the PEER BINARY inside a specific sandbox and nothing is
# inherited between agents, so a preset on the wrong plane is useless AND a
# containment change. There is deliberately no default target: an implicit
# default is what caused the problem.
#
# OWNERSHIP RULE (filename convention, evaluated against the table below)
#
#   <agent>-*.yaml   belongs to that agent, where <agent> is one of the names in
#                    AGENTS. Matched against the table, not by splitting on the
#                    first dash — `falda-egress.yaml` is a capability preset, not
#                    an agent named "falda".
#   everything else  is a SHARED capability preset (google-workspace, tavily,
#                    telegram, web-readonly, falda, managed-inference-widen).
#                    Owned by no agent; applied only with an explicit --shared.
#
# Gandalf's whole current preset set is unprefixed, so his real invocation is
# `apply-policies.sh gandalf --shared`. That friction is intentional: pushing a
# capability preset onto a plane is a containment decision, so it should be typed.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path

# Known agents and the plane each one lives on. Keep in sync with PLANE_PORT in
# ops/nmc.sh and PLANES in ops/agent-planes.sh.
#   gandalf  :8080  frozen v0.0.55 stack, driven by `nemohermes gandalf ...`
#   cecat    :8090  } v0.0.108 sidecar — MUST route through ops/nmc.sh. A bare
#   luoji    :8091  } `nemoclaw` aimed at these ports relaunches a gateway there
#                     with plaintext auth and Gandalf's DB (93-restart incident,
#                     2026-09-01). See the header of ops/nmc.sh.
AGENTS="gandalf cecat luoji"

REPO=$(repo_root)
DIR="$REPO/bringup/50-openshell-policies"

usage() {
  cat <<EOF
usage: bash ops/apply-policies.sh <agent> [--shared] [--dry-run]

  <agent>      one of: $AGENTS   (required — there is no default)
  --shared     also apply the unprefixed capability presets (opt-in)
  --dry-run    print what would be pushed where, change nothing
  -n           alias for --dry-run
EOF
}

AGENT=""; SHARED=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shared)        SHARED=1 ;;
    --dry-run|-n)    DRY=1 ;;
    -h|--help)       usage; exit 0 ;;
    -*)              usage >&2; fail "Unknown option: $1" ;;
    *)               [ -z "$AGENT" ] || { usage >&2; fail "Only one agent may be given (got '$AGENT' and '$1')."; }
                     AGENT="$1" ;;
  esac
  shift
done

if [ -z "$AGENT" ]; then
  usage >&2
  fail "No agent given. This script will not guess a target — name the plane explicitly."
fi

case " $AGENTS " in
  *" $AGENT "*) ;;
  *) usage >&2; fail "Unknown agent '$AGENT' (known: $AGENTS)." ;;
esac

[ -d "$DIR" ] || fail "Missing $DIR"

# Which agent, if any, owns this filename. Empty = shared capability preset.
owner_of() { # owner_of <basename>
  local b="$1" a
  for a in $AGENTS; do
    case "$b" in "$a"-*) printf '%s' "$a"; return ;; esac
  done
  printf ''
}

# Build the exact argv for a policy-add on this agent's plane, into ARGV.
# Printed verbatim in --dry-run, so preview and execution cannot diverge.
policy_add_argv() { # policy_add_argv <agent> <file>
  case "$1" in
    gandalf) ARGV=(nemohermes gandalf policy-add --from-file "$2" --yes) ;;
    *)       ARGV=(bash "$REPO/ops/nmc.sh" "$1" policy add --from-file "$2" --yes) ;;
  esac
}

policy_list_argv() { # policy_list_argv <agent>
  case "$1" in
    gandalf) ARGV=(nemohermes gandalf policy-list) ;;
    *)       ARGV=(bash "$REPO/ops/nmc.sh" "$1" policy list) ;;
  esac
}

# Partition the directory. Files are collected in sorted order.
SELECTED=""; SKIPPED=""
for f in "$DIR"/*.yaml; do
  [ -f "$f" ] || continue                       # unmatched glob
  b=$(basename "$f")
  o=$(owner_of "$b")
  if [ "$o" = "$AGENT" ]; then
    SELECTED="$SELECTED$f"$'\n'
  elif [ -z "$o" ] && [ "$SHARED" -eq 1 ]; then
    SELECTED="$SELECTED$f"$'\n'
  else
    SKIPPED="$SKIPPED$b (${o:-shared})"$'\n'
  fi
done

note "Target: $AGENT   shared=$([ "$SHARED" -eq 1 ] && echo yes || echo no)   dry-run=$([ "$DRY" -eq 1 ] && echo yes || echo no)"

if [ -n "$SKIPPED" ]; then
  printf '%s\n' "$SKIPPED" | sed '/^$/d' | while read -r line; do
    note "skip  $line"
  done
fi

if [ -z "$SELECTED" ]; then
  warn "Nothing to apply for '$AGENT'."
  [ "$SHARED" -eq 1 ] || warn "Unprefixed capability presets were skipped; add --shared to include them."
  exit 0
fi

while IFS= read -r f; do
  [ -n "$f" ] || continue
  policy_add_argv "$AGENT" "$f"
  if [ "$DRY" -eq 1 ]; then
    printf '[dry-run] %s\n' "$(printf '%q ' "${ARGV[@]}")"
  else
    note "Applying: $(basename "$f") -> $AGENT"
    "${ARGV[@]}" 2>&1 | grep -E '(✓|preset:|Endpoints|unchanged|Applied|Error|error)' | sed 's/^/   /'
  fi
done <<EOF
$SELECTED
EOF

policy_list_argv "$AGENT"
if [ "$DRY" -eq 1 ]; then
  printf '[dry-run] %s\n' "$(printf '%q ' "${ARGV[@]}")"
  exit 0
fi

info "Done. Current policy presets on $AGENT:"
"${ARGV[@]}" 2>&1 | grep -E '●|○' | head -30
