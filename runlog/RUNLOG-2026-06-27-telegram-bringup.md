# RUNLOG 2026-06-27 — Telegram bring-up + session reconciliation

**Operator:** catlett (offline in transit)
**Driver:** Claude Code (Opus 4.7) on the Spark
**Outcome:** Telegram adapter provisioned and live; 3 platforms connected
(api_server, slack, telegram). All log-based smoke gates green. Operator DM
round-trip pending operator return.

---

## Why this happened

Two distinct things landed in one rebuild:

1. **Telegram bring-up.** Operator wanted DM-able Telegram bot alongside the
   existing Slack adapter. Bot token + allowed-user ID supplied. Daily briefing
   stays Slack-only (no outbound Telegram cron requested).

2. **Latent rebuild blocker discovered & fixed.** `~/.nemoclaw/onboard-session.json`
   had `provider: vllm-local` paired with `credentialEnv: COMPATIBLE_ANTHROPIC_API_KEY`
   — a state-mismatch from earlier bringup that slipped past the upstream
   legacy-migration branch (only `OPENAI_API_KEY` is auto-cleared for local-
   inference providers). Would have blocked *any* future rebuild, not just
   Telegram.

## The diagnosis arc (paired md files in `bringup/70-telegram/`)

1. `implementation.md` — first session log; correctly identified that
   `~/.hermes/.env` isn't the credential path. **Wrong about next step**
   (recommended channels-add + rebuild based on partial info). Superseded.
2. `NEXT-STEPS-FOR-CLAUDE-CODE.md` — analysis from operator's Mac after
   reading runlogs; recommended skipping `channels add` and hand-injecting
   `platforms.telegram` into config.yaml. **Wrong premise** (assumed Slack
   inbound today came from a manual config.yaml injection; it doesn't).
   Superseded.
3. `phase-a-findings.md` — read-only diagnosis on the live box that overturned
   the NEXT-STEPS premise. Showed Slack inbound runs via
   `NEMOCLAW_MESSAGING_CHANNELS_B64` + `openshell:resolve:env:...` token
   placeholders, all rebuild-safe. Recommended the supported `channels add`
   path.
4. `phase-b-blocked.md` — Phase B execution log; hit the
   `COMPATIBLE_ANTHROPIC_API_KEY` preflight wall, stopped before destroying
   anything.
5. `status-for-external-review.md` — self-contained snapshot for external
   review.
6. `REVIEW-RESPONSE-AND-PROCEED.md` — external review approved Option 3
   (reconcile session.json), flagged two risks (R1: stored token was the
   pre-rotation revoked one; R2: allowlist must use `TELEGRAM_ALLOWED_IDS`,
   not the README/template's `_USERS`).

## What was actually done today

### Phase A — diagnosis (no state change)
Already documented in `phase-a-findings.md`.

### Phase B step 1 — read-only pre-checks (this runlog)
- Backed up `~/.nemoclaw/onboard-session.json` to
  `.bak-2026-06-27-pre-credentialenv-fix`.
- Grepped `~/gandalf-bringup/nemoclaw-src` for every consumer of
  `session.credentialEnv`:
  - `rebuild.ts` preflight (the gate we want to bypass).
  - `sandbox/config.ts:878` (`config rotate-token` — operator-explicit, not
    auto).
  - `onboard/agent-resume-state.ts:29` (literally sets it null itself).
  - `state/onboard-session.ts:1183` + `onboard/machine/events.ts:124` (pure
    projections; `nullableString(null)` is safe).
  All safe to set null.
- Confirmed live `/sandbox/.hermes/config.yaml` model.provider=`custom`
  base_url=`https://inference.local/v1` — vLLM path, no Anthropic config.
  Gateway env carries no `COMPATIBLE_ANTHROPIC_API_KEY`. Sandbox runs healthy
  without the field, so setting it null at the session level breaks nothing.
- **R1 confirmed:** computed sha256 of revoked token (`867ce3e6...`) matched
  the registry's `providerCredentialHashes.TELEGRAM_BOT_TOKEN` exactly. The
  OpenShell credential store held the dead token. Re-provisioning required
  before rebuild or the adapter would Telegram-401.

### Phase B step 2 — session reconciliation
- Edited `~/.nemoclaw/onboard-session.json`: `credentialEnv:
  "COMPATIBLE_ANTHROPIC_API_KEY"` → `null`. Provider/sandboxName preserved,
  mode 600 preserved. Backup retained for rollback.

### Phase B step 3 — re-provision new token + allowlist
- Sourced new `~/.hermes/.env` (already had the rotated bot token from
  earlier in the day).
- Exported `TELEGRAM_ALLOWED_IDS=$TELEGRAM_ALLOWED_USERS` (shim — see
  followup section) and `TELEGRAM_REQUIRE_MENTION=0`.
- Verified env-token sha256 (`caabb15c...`) matched new live token, not the
  old one.

### Phase B step 4 — rebuild
- `echo y | nemohermes gandalf channels add telegram` — completed cleanly:
  - Provider `gandalf-telegram-bridge` recreated with new credential (visible
    in build output: `✓ Deleted provider gandalf-telegram-bridge / ✓ Created
    provider gandalf-telegram-bridge`).
  - NemoClaw bake `NEMOCLAW_MESSAGING_ALLOWED_IDS_B64` includes telegram.
  - Sandbox image rebuilt to `openshell/sandbox-from:1782570229`.
  - New container Ready in <2 min.
- `bash ops/post-rebuild.sh` — everything restored cleanly except a smoke-test
  false negative (see followup section).

### Phase B step 5 — smoke gates (all green)
Read from PID 195's open-but-deleted `gateway.log` FD via `/proc/195/fd/8`
(needed because `ops/post-rebuild.sh`'s state-restore overwrote the on-disk
log file after the gateway already opened its FDs — see followup section).

| # | Gate | Result |
|---|---|---|
| 1 | `gateway.log` shows `✓ api_server connected`, `✓ telegram connected`, `✓ slack connected`, `Gateway running with 3 platform(s)` | ✓ |
| 2 | Inference round-trip via `127.0.0.1:8642/v1/chat/completions` returns 200 | ✓ (1.5s) |
| 3 | `NEMOCLAW_MESSAGING_ALLOWED_IDS_B64` decodes to `{"telegram":["8730021403"],"slack":["U05H8JM8NFQ"]}` | ✓ |
| 4 | Outbound TLS to `api.telegram.org` (live polling) | ✓ (`getUpdates` every ~10s) |
| 5 | Slack not regressed — websocket to `wss-primary.slack.com:443` upgraded | ✓ |

### Phase B step 6 — held for operator
"Provisioned, gateway-verified. Pending operator DM round-trip on return."

## State changes summary (snapshot-deltas)

- Snapshots: v14 `pre-telegram`, **v15 `pre-telegram-add-v2`** (rollback target).
- `~/.nemoclaw/onboard-session.json`: `credentialEnv` null.
  Backup: `.bak-2026-06-27-pre-credentialenv-fix`.
- `~/.nemoclaw/sandboxes.json`: `messagingChannels: ["slack", "telegram"]`.
  `providerCredentialHashes.TELEGRAM_BOT_TOKEN` now hash of NEW token
  (`caabb15c...`).
- OpenShell policy: v3 in fresh sandbox (versioning reset on rebuild).
  Active: `slack`, `telegram`, `npm`, `pypi`, `huggingface`, `brew`,
  `local-inference`, plus custom `google-workspace-egress`,
  `managed-inference-widen`, `tavily-egress`, `telegram-egress`,
  `web-readonly-egress`.
- Container: `openshell-gandalf-c34590f5-...`. Started 14:24Z. Gateway PID 195.
- `/sandbox/.hermes/.env`: includes new Tavily key, new Telegram bot token,
  HERMES_SUPPRESS_SETHOME_NOTICE.
- `/etc/nemoclaw/hermes.config-hash`: recomputed.

## Followups (low-priority, not blocking)

### F1 — Upstream PR opportunity: widen the legacy-migration branch
`~/gandalf-bringup/nemoclaw-src/src/lib/actions/sandbox/rebuild.ts:334-345`
hand-clears `credentialEnv` when `provider in (vllm-local, ollama-local)` AND
`credentialEnv === "OPENAI_API_KEY"`. The check should also cover other
"compatible-*" credential envs (`COMPATIBLE_ANTHROPIC_API_KEY`,
`COMPATIBLE_API_KEY`) that can end up on a local-inference session after a
mid-life `set-inference` or rebuild path. Worth a PR.

### F2 — `ops/post-rebuild.sh` smoke-test false negative
The gmail-search smoke test at line 227 greps for output starting with `^\[`
(expecting a JSON array). When the inbox has no unread messages, the script
returns `No messages found.` (plain text) and the grep fails — even though
the API call succeeded, auth works, egress works. Today this masked nothing
real but `set -eu` causes `fail()` to abort the script. Fix: change the
positive predicate to one that matches both an empty array `[]` and the
no-messages string, e.g. `head -1 | grep -qE '^\[|^No messages found\.$'`.

### F3 — `ops/post-rebuild.sh` state-restore clobbers live gateway log files
The post-rebuild state restore (after the gateway has already started and
opened its log file FDs) writes over `/sandbox/.hermes/logs/gateway.log` etc.
with the backup-time contents. The gateway keeps writing to the deleted-but-
open FD, which is then only readable via `/proc/<pid>/fd/N`. Visible symptom:
`cat /sandbox/.hermes/logs/gateway.log` looks stale and confusing. Fix
options: (a) restore state BEFORE the gateway starts; (b) skip restoring
log/ from the backup entirely; (c) `truncate` the new files after restore
so the gateway's open FDs see the fresh content.

### F4 — README/template uses `TELEGRAM_ALLOWED_USERS`; upstream reads `TELEGRAM_ALLOWED_IDS`
- `bringup/secrets.example.env` line 41: `TELEGRAM_ALLOWED_USERS=...`
- `bringup/70-telegram/README.md` Part B step 4b: same.
- `~/.hermes/.env`: currently uses `_USERS` (works only because today's
  channels-add was shimmed inline by also exporting `_IDS`).

Upstream (`nemoclaw-src/src/lib/sandbox/channels.ts:68`) reads
`TELEGRAM_ALLOWED_IDS`. Rename the .env line + template + README to
`_IDS`. Quick-grep Hermes itself for any legacy `_USERS` reader before
removing (none found in initial scan).

### F5 — `_USERS` shim is currently the only thing keeping the allowlist working
Until F4 lands, future rebuilds need the operator (or a script) to
`export TELEGRAM_ALLOWED_IDS=$TELEGRAM_ALLOWED_USERS` before any
`channels add telegram` re-run, or the allowlist will silently empty. Pin
this in CLAUDE.md's destructive-ops section if F4 doesn't land soon.

### F6 — Snapshot retention
Per reviewer recommendation: keep at least v3 `phase-h-baseline`, v14
`pre-telegram`, v15 `pre-telegram-add-v2`. Plus add a `telegram-live` once
operator confirms DM round-trip. Older snapshots eligible for pruning.

## Files touched / committed

- `~/.nemoclaw/onboard-session.json` (edited; not in repo)
- `~/.hermes/.env` (rotated keys earlier today; not in repo)
- `runlog/RUNLOG-2026-06-27-telegram-bringup.md` (this file; tracked)
- `bringup/70-telegram/{implementation,phase-a-findings,phase-b-blocked,
  status-for-external-review,REVIEW-RESPONSE-AND-PROCEED}.md` (history;
  already committed earlier)

## Rollback

If anything turns out to be wrong after operator DM verification:
`nemohermes gandalf snapshot restore pre-telegram-add-v2` (v15). This
reverts the sandbox image only; `~/.nemoclaw/onboard-session.json` would
need to be restored from `.bak-2026-06-27-pre-credentialenv-fix` separately
if the credentialEnv fix needs reverting too.
