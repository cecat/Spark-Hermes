# RUNLOG 2026-06-29 — Slack sethome notice: root cause + fix

**Operator:** catlett (back from transit, on the Spark)
**Driver:** Claude Code (Opus 4.7)
**Trigger:** Operator reported the "📬 No home channel is set for Slack — type
/hermes sethome" notice was firing on every Slack DM, two days after the
2026-06-27 Telegram rebuild.

**Outcome:** symptom resolved. Underlying slash-command delivery still has a
known bug in the response_url path; tracked as a followup.

---

## TL;DR

The sethome notice had been firing because **the Slack app manifest never
declared `/hermes` as a slash command.** Slack acked typed commands with
"Running /hermes..." and silently dropped them — no app to route them to.
A prior session had reached for a *symptom suppression* patch
(`HERMES_SUPPRESS_SETHOME_NOTICE` + a runtime patch to `gateway/run.py`)
rather than asking why the slash command didn't work in the first place.

Today: declared `/hermes` in the manifest, removed the suppression workaround,
discovered a second bug (response_url POSTs to `hooks.slack.com` fail from the
long-running gateway process), and worked around the immediate symptom by
writing `SLACK_HOME_CHANNEL` directly into the sandbox `.env` so the per-
platform notice gate is satisfied without needing `/hermes sethome` to work.

Three platforms still connected (`api_server`, `slack`, `telegram`); operator
confirmed the sethome notice no longer fires on new Slack DMs.

---

## Diagnostic arc

### Symptom (operator-reported)
Every Slack DM with Gandalf triggered the sethome notice. CLAUDE.md's
"Custom patches" section claimed the notice was suppressed via
`HERMES_SUPPRESS_SETHOME_NOTICE=1` + a `run.py` patch applied by
`ops/post-rebuild.sh`. Operator (correctly) flagged this as suspicious —
"isn't this jury-rigged?"

### Layer 1 — the workaround wasn't even in place
- `HERMES_SUPPRESS_SETHOME_NOTICE=1` was in `/sandbox/.hermes/.env` but **not
  in the gateway process env** (env loader runs in-process at boot; the value
  was added to .env after boot, never re-read).
- The `gateway/run.py` patch (`SPARK-HERMES PATCH 2026-06-20` marker) was
  **absent from the live file**. The `.orig-pre-sethome-patch` backup was
  present, dated 2026-06-27 14:24 (yesterday's `post-rebuild.sh`), with
  identical bytes to the live unpatched file. Conclusion: the patch had been
  applied at runtime then wiped when the container's writable layer was reset
  at 15:57 the same day.
- Container restartCount=1, started 2026-06-27T15:57:34Z. Something cycled
  the container ~93 minutes after yesterday's rebuild — the patch died there.
- Integrity hash in `/etc/nemoclaw/hermes.config-hash` **didn't match live
  files** (config.yaml and .env had both been touched after the last rehash —
  by Telegram's `/sethome` adding `TELEGRAM_HOME_CHANNEL=...`). The gateway
  was one cycle away from refusing to launch. **Ticking-bomb finding.**

### Layer 2 — operator question reframed the investigation
> "Suppressing an error message seems jury rigged, as opposed to FIXING the
> underlying problem that the error message symptom is caused by?"

Reframed: why doesn't `/hermes sethome` actually work? The notice points at
it as the canonical fix; if it worked, no suppression patch would ever have
been needed.

Confirmed the slash command was reachable internally:
- Hermes implements `/hermes` and `/sethome` in `/opt/hermes/gateway/run.py`
  + `hermes_cli/commands.py:112`.
- `slack_subcommand_map()` exposes `sethome → /sethome`.
- `_handle_slash_command` rewrites `/hermes sethome` → dispatch to
  `_handle_set_home_command` which writes `SLACK_HOME_CHANNEL` to `.env` and
  updates in-memory config.

But the agent.log had **zero `inbound message` lines for any slash command
attempt** — the events weren't reaching Hermes at all.

### Layer 3 — the real cause: Slack app manifest had no slash_commands
`bringup/20-slack-app/manifest.yaml` declared scopes, events, and Socket Mode
but **never declared any slash commands.** Without a `features.slash_commands`
section, Slack has no idea where to route `/hermes`. The "Running /hermes..."
message you see in Slack is just Slack's ephemeral ack of the typed command;
the request never goes anywhere.

This was completely independent of NemoClaw, Hermes, or OpenShell. Standard
Slack app behavior. The CLAUDE.md note ("slash command isn't registered in
this NemoClaw-mediated setup") wrongly attributed it to NemoClaw — NemoClaw
has no role in slash-command routing.

### Layer 4 — Slack workspace ownership conflict
After declaring `/hermes` and reinstalling, the operator got a Slack notice:
> "Your workspace has been using /hermes to kick off certain actions with
> Somm. Recently Gandalf was installed to Trillion Parameter Consortium with
> the same command. Now when people enter /hermes, it'll run the action set
> up by Gandalf."

`/hermes` had been claimed by a different app (`Somm`) in TPC. The reinstall
moved ownership to Gandalf. This explains why the symptom had been latent
for nine days — even if a manifest fix had been attempted earlier, Somm
might have stayed the registered owner depending on which app was reinstalled
last.

### Layer 5 — second bug: response_url POSTs fail from the live gateway
With ownership fixed, `/hermes help` reached the gateway (confirmed in
`gateway.log`: handler ran, no errors generated). But the user still saw
"Running /hermes..." indefinitely.

Hermes's slash-command result delivery uses Slack's `response_url` (signed
one-time callback URL on `hooks.slack.com`) via raw aiohttp. The live
gateway process's aiohttp **consistently fails** the POST with `Cannot
connect to host hooks.slack.com:443 [Temporary failure in name resolution]`.
Curl from inside the same sandbox succeeds; aiohttp from a **fresh** Python
subprocess in the sandbox also succeeds. Only the long-lived gateway python
process's aiohttp fails — and only against `hooks.slack.com`. Other Slack
hosts (slack.com, api.slack.com, wss-primary.slack.com) work fine for the
same process.

Most likely cause: OpenShell L7 proxy's `request_body_credential_rewrite:
true` setting on `hooks.slack.com` is mangling unauthenticated callback
POSTs in a way that aiohttp surfaces as a DNS error. Not verified —
documented as a followup; deeper investigation needs an isolated test
without disrupting service.

Hermes's response_url failure is also logged as `non-fatal — user saw the
ack already`, but the result is **not** automatically retried over Socket
Mode. So the result is lost and Slack sits on "Running /hermes..." forever.

### Layer 6 — pragmatic fix for the symptom
Since `/hermes sethome` couldn't deliver its result anyway, wrote
`SLACK_HOME_CHANNEL=D0BBDHYCWPK` directly into `/sandbox/.hermes/.env`,
recomputed the integrity hash, restarted the gateway. The sethome-notice
gate (`if not os.getenv(env_key)` in `run.py`) is now satisfied; the notice
no longer fires.

Operator confirmed: no notice on subsequent DMs.

---

## Changes committed (db1bbbb + this runlog)

### `bringup/20-slack-app/manifest.{yaml,json}`
- Added `features.slash_commands` declaring `/hermes` (one command — Hermes's
  adapter rewrites `/hermes <sub>` → `/<sub>` internally so one declaration
  covers the full surface).
- Added `commands` bot scope (Slack rejects manifests with slash commands
  but no `commands` scope).
- Synced `manifest.json` to `manifest.yaml`: previously missing
  `groups:read` + `reactions:read` from JSON.

### `bringup/20-slack-app/README.md`
- New "Day 2" section: paste-reinstall procedure for updating a live app's
  manifest; explains why slash commands need this step; how to verify.
- Updated scope list to reflect current manifest.

### `ops/post-rebuild.sh`
- Removed the `gateway/run.py` source patch entirely (didn't survive
  container restarts; was masking the slash-command issue).
- Removed `HERMES_SUPPRESS_SETHOME_NOTICE` from `EXTRA_ENV_KEYS`.
- Added `SLACK_HOME_CHANNEL` + `TELEGRAM_HOME_CHANNEL` to `EXTRA_ENV_KEYS` so
  whatever `/hermes sethome` writes survives future rebuilds (and to backstop
  manual writes like today's).

### `bringup/secrets.example.env`
- Renamed `TELEGRAM_ALLOWED_USERS` → `TELEGRAM_ALLOWED_IDS` (upstream
  NemoClaw reads `_IDS`; the `_USERS` name in earlier docs was wrong).
  Closes followup F4 from RUNLOG-2026-06-27.

### Local-only (not in repo)
- `~/.hermes/.env`: removed dead `HERMES_SUPPRESS_SETHOME_NOTICE=1` line;
  corrected `SLACK_HOME_CHANNEL` from the retired `C0BAV5A4C7R` to the DM
  `D0BBDHYCWPK`; renamed `TELEGRAM_ALLOWED_USERS` → `TELEGRAM_ALLOWED_IDS`.
  Mode 600 preserved.
- `/sandbox/.hermes/.env`: added `SLACK_HOME_CHANNEL=D0BBDHYCWPK`.
- `/etc/nemoclaw/hermes.config-hash`: recomputed twice (once after the
  Tavily rotation drift, once after the SLACK_HOME_CHANNEL write).
- `CLAUDE.md` (gitignored): removed the run.py patch line; added an
  integrity-hash-drift warning in the env-flow section.
- `~/.claude/.../memory/project_hermes_sethome_notice_suppressed.md`:
  rewrote completely. Now documents the manifest fix as the proper solution
  and explicitly warns against bringing the suppression hack back.

---

## State changes summary

- Snapshots: v17 `pre-sethome-fix-2026-06-29` taken before any state change
  (rollback target).
- Slack app: `/hermes` slash command declared, `commands` scope added,
  workspace reinstalled (still using the same bot/app tokens — confirmed by
  hash compare). Slack reassigned `/hermes` ownership from Somm to Gandalf.
- Container: PID 197 (was 198 before today's two restarts).
- Slack: Socket Mode connected at 18:48:12Z.
- Telegram: long-polling at 18:48:11Z.
- `/sandbox/.hermes/.env` carries SLACK_HOME_CHANNEL + TELEGRAM_HOME_CHANNEL.
- Integrity hash matches live files.

---

## Followups

### F-30 — debug `hooks.slack.com` response_url failure (BLOCKING SLASH COMMANDS)
Slash commands reach the gateway and the handler runs, but the result
delivery via `aiohttp.post(response_url)` fails on the live long-lived
gateway python with `Temporary failure in name resolution` even though:
- DNS resolves fine (`getent` works)
- curl POST to `hooks.slack.com` succeeds from same sandbox
- aiohttp from a fresh subprocess in same sandbox succeeds
- Same gateway process successfully reaches slack.com, api.slack.com,
  wss-primary.slack.com via Slack SDK

Hypothesis: OpenShell L7 proxy's `request_body_credential_rewrite: true` on
`hooks.slack.com` mangles unauthenticated callback POSTs in a way that
surfaces as a misleading DNS error to aiohttp. Possible fixes:
1. Custom egress preset for `hooks.slack.com` without
   `request_body_credential_rewrite`.
2. Monkey-patch Hermes to use `requests` (sync) for `response_url` instead
   of `aiohttp`.
3. Upstream patch to fall back to Socket Mode if `response_url` POST fails.

Until fixed, slash commands appear to hang in Slack DM (operator sees
"Running /hermes..." forever even though the underlying action succeeds
server-side). `/hermes sethome` was the canonical user-facing path to set
home; we worked around it today by writing `SLACK_HOME_CHANNEL` directly.

### F-31 — `ops/post-rebuild.sh` state-restore overwrites live log file FDs
(carryover from RUNLOG-2026-06-27 F3, not addressed today)

### F-32 — `ops/post-rebuild.sh` gmail smoke test is a false negative
(carryover from RUNLOG-2026-06-27 F2, not addressed today)

### F-33 — Hermes should rehash integrity file when it writes `.env`
The gateway writes to `/sandbox/.hermes/.env` at runtime (via `/sethome`,
possibly other paths) but does not recompute `/etc/nemoclaw/hermes.config-hash`.
This silently drifts and the next gateway-cycle refuses to start. **Upstream
fix would be: when Hermes's `save_env_value` is called, also recompute the
NemoClaw hash file.** Worth a PR.

### F-34 — Investigate `Somm` slash-command conflict
Slack told us `/hermes` was claimed by an app called `Somm` in TPC. We now
own it. If anyone in TPC was using Somm's `/hermes` for something, their
usage now silently routes to Gandalf. Find Somm (probably installed by
another TPC member or app marketplace) and decide if we need to coordinate.

### F-35 — Container restart logged 2026-06-27 ~15:57 unexplained
Investigation showed restartCount=1 with start time 90 minutes after
yesterday's rebuild. What restarted it? Worth grepping nemoclaw / docker
logs to understand whether something triggers periodic restarts that would
wipe runtime patches generally.

---

## Files of interest

- Repo commits: `db1bbbb` (manifest + workaround removal), this runlog.
- Live container: `openshell-gandalf-c34590f5-...`, PID 197.
- Snapshot rollback: v17 `pre-sethome-fix-2026-06-29` (took today).

## Rollback if anything regresses

`nemohermes gandalf snapshot restore pre-sethome-fix-2026-06-29` (v17).
Restores sandbox state from 17:26Z today (before any of the day's writes).
For the manifest change: Slack's App Manifest page has revision history;
revert there if needed.
