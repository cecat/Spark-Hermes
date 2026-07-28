#!/usr/bin/env bash
# RETIRED 2026-07-28 — this script did nothing useful for six weeks.
#
# It pushed gandalf/memories/*.md into /sandbox/.hermes/memories/.
# NOTHING IN HERMES READS THAT DIRECTORY.
#
# Verified against Hermes v0.14.0 source:
#   MemoryStore.load_from_disk()  (tools/memory_tool.py:126-132)
#   opens ONLY the hard-coded filenames MEMORY.md and USER.md. No glob, no
#   numeric-prefix scan, and no config key anywhere in Hermes that would add
#   more. Every 00-identity.md / 30-guardrails.md uploaded by this script was
#   inert on arrival.
#
# The replacement is ops/apply-soul.sh, which renders the same source files
# (now in gandalf/soul/) into /sandbox/.hermes/SOUL.md — a path Hermes really
# does load, on every agent construction, with a 20,000-char budget.
#
# Full map of what loads and what doesn't: docs/HERMES-LOAD-PATHS.md
#
# This stub is kept rather than deleted so that anything still calling the old
# name — a runbook, post-rebuild.sh, a person, or the agent itself — gets an
# explanation instead of "command not found".
set -eu

cat >&2 <<'EOF'

  apply-memories.sh is retired and does nothing.

  Reason: /sandbox/.hermes/memories/ is read by no Hermes code path. Files
  pushed there never reached the agent. See docs/HERMES-LOAD-PATHS.md.

  Use instead:
      bash ops/apply-soul.sh              # push gandalf/soul/ -> SOUL.md
      bash ops/apply-soul.sh --dry-run    # preview without uploading

EOF
exit 1
