#!/usr/bin/env bash
# Reconcile `hermes cron list` with the cron.jobs[] block in ~/.hermes/config.yaml.
#
# Anything in config.yaml not running gets created. Anything running but NOT in
# config.yaml gets removed (with a per-item confirmation prompt unless --yes is passed).
#
# Flags:
#   --dry-run   Show what would change without changing anything.
#   --yes       Skip the per-item confirmation for removals.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
load_hermes_env
require_hermes_config

DRY=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --yes|-y)  YES=1 ;;
    *) fail "Unknown flag: $arg" ;;
  esac
done

CONTAINER=$(gandalf_container)

# Parse cron.jobs[] from ~/.hermes/config.yaml into tab-separated name|sched|deliver|prompt.
# Expand ${slack.home_channel_id}-style refs against the same config file.
PARSED=$(python3 - "$HERMES_CONFIG" <<'PYEOF'
import os, re, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
def resolve(s):
    """Replace ${a.b.c} with the corresponding config value."""
    def sub(m):
        key = m.group(1); cur = cfg
        for k in key.split('.'):
            cur = cur.get(k) if isinstance(cur, dict) else None
            if cur is None: return m.group(0)
        return str(cur)
    return re.sub(r'\$\{([a-zA-Z0-9_.]+)\}', sub, s)
out = []
for j in (cfg.get('cron', {}).get('jobs') or []):
    name = j.get('name') or ''
    sched = j.get('schedule') or ''
    deliver = resolve(j.get('deliver') or '')
    prompt = (j.get('prompt') or '').strip().replace('\t',' ')
    out.append("\t".join([name, sched, deliver, prompt]))
print("\n".join(out))
PYEOF
)

if [ -z "$PARSED" ]; then
  warn "No jobs declared in $HERMES_CONFIG (cron.jobs[] is empty)."
  exit 0
fi

# Get existing job names from hermes cron list
EXISTING=$(sb_exec /usr/local/bin/hermes cron list 2>/dev/null | awk '/Name:/ {print $2}' | sort -u || true)

# Wanted names from cron.yaml
WANTED=$(echo "$PARSED" | cut -f1 | sort -u)

# What to create (in wanted, not in existing)
TO_CREATE=$(comm -23 <(echo "$WANTED") <(echo "$EXISTING"))
# What to remove (in existing, not in wanted)
TO_REMOVE=$(comm -13 <(echo "$WANTED") <(echo "$EXISTING"))

# Report plan
note "Existing jobs in sandbox: $(echo "$EXISTING" | grep -v '^$' | wc -l)"
note "Wanted jobs from config.yaml: $(echo "$WANTED" | wc -l)"
[ -n "$TO_CREATE" ] && warn "Will create: $(echo $TO_CREATE | tr '\n' ' ')" || info "No new jobs to create."
[ -n "$TO_REMOVE" ] && warn "Will remove: $(echo $TO_REMOVE | tr '\n' ' ')" || info "No stale jobs to remove."

if [ "$DRY" -eq 1 ]; then
  note "Dry run — no changes made."
  exit 0
fi

# Create new jobs
echo "$PARSED" | while IFS=$'\t' read -r name sched deliver prompt; do
  if echo "$TO_CREATE" | grep -qx "$name"; then
    note "Creating job: $name (schedule=$sched, deliver=$deliver)"
    sb_exec /usr/local/bin/hermes cron create "$sched" "$prompt" \
      --name "$name" \
      --deliver "$deliver" 2>&1 | head -5
  fi
done

# Remove stale jobs (with confirmation unless --yes)
for name in $TO_REMOVE; do
  if [ "$YES" -ne 1 ]; then
    printf "Remove stale job '%s'? [y/N]: " "$name"
    read -r ans
    [ "$ans" = "y" ] || { note "Skipped removal of $name"; continue; }
  fi
  ID=$(sb_exec /usr/local/bin/hermes cron list 2>/dev/null | awk -v n="$name" '$1 ~ /^[0-9a-f]+$/ {id=$1} /Name:/ && $2==n {print id; exit}')
  if [ -n "$ID" ]; then
    sb_exec /usr/local/bin/hermes cron remove "$ID" 2>&1 | head -3
    info "Removed: $name ($ID)"
  else
    warn "Could not resolve id for $name"
  fi
done

info "Done. Current state:"
sb_exec /usr/local/bin/hermes cron list 2>&1 | head -20
