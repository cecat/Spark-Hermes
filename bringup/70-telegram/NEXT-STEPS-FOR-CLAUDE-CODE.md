# Telegram bring-up — corrected next steps for Claude Code

**Read this before doing anything on the Spark.** It supersedes the "what still
needs to happen" section of `implementation.md`. Author: analysis from the Mac
repo, 2026-06-27, after reviewing `implementation.md`, `runlog/HANDOFF-2026-06-18.md`,
and `runlog/RUNLOG-2026-06-17-bringup.md` / `RUNLOG-2026-06-21-tavily-pivot.md`.

---

## 1. What you (the previous session) got right — keep it

- Applying `telegram-egress` (policy v12) was correct and is needed. ✅
- Taking the `pre-telegram` snapshot before any risky step was the right call. ✅
- **Discovering that `~/.hermes/.env` is not how messaging creds reach the
  gateway** (they appear as `openshell:resolve:env:...` placeholders, and
  channel config is baked into `NEMOCLAW_*_CONFIG_B64`) was a genuine, correct
  finding. ✅
- Stopping before the rebuild to get sign-off was correct. ✅

None of that is a rabbit hole. The problem is the **plan** you stopped in front
of, not the work you did.

## 2. The thing the report missed (this is the important part)

The report's next step — `nemohermes gandalf channels add telegram` → rebuild →
`post-rebuild.sh` → "DM the bot and expect a reply" — **will not produce a
working conversational Telegram bot, and may regress Slack.** Here's why,
straight from this repo's own runlogs:

- **`channels add <x>` only wires OUTBOUND delivery, not inbound chat.** Per
  `RUNLOG-2026-06-17` and `HANDOFF-2026-06-18`: in this NemoHermes 0.1.0 /
  Hermes v2026.5.16 build, the generated `/sandbox/.hermes/config.yaml` only
  enables `platforms.api_server`. `channels add slack` set up a *gateway-level
  bridge for cron delivery* but did **not** add `platforms.slack`. Inbound
  (DM/@mention → Hermes) does not work from `channels add` alone.

- **Inbound was later turned on by hand, and that fix is NOT rebuild-safe.**
  `RUNLOG-2026-06-21` line 191 reports the gateway running with **"both
  api_server and slack platforms connected"** — so between 06-18 and 06-21
  someone injected `platforms.slack` into `/sandbox/.hermes/config.yaml` and
  re-hashed `/etc/nemoclaw/hermes.config-hash` (the start-script SHA256-verifies
  config.yaml and refuses to launch if it's edited without rehashing —
  `RUNLOG-2026-06-17` line 198). **That injection does not exist anywhere in the
  repo** — `post-rebuild.sh` re-syncs `.env` keys and re-hashes, but it does
  **not** re-add any `platforms.*` block to config.yaml.

**Consequence of the report's plan:** `channels add telegram` triggers a sandbox
**rebuild**, which regenerates config.yaml from the api_server-only generator.
After that rebuild:
- `platforms.slack` is **gone** → you've **broken** the working Slack inbound bot.
- `platforms.telegram` was never added → Telegram inbound still doesn't work.
- You'd have spent a rebuild to go backwards.

**Don't confuse the two senses of "outbound."** The bot **replying to a DM** is
sent by the `platforms.telegram` adapter itself — a conversational adapter is
two-way, receiving the message and sending the reply over the same connection.
That is required and is the whole point. What's out of scope is something
different: duplicating the **scheduled daily briefing** (an unprompted, timed
push) to Telegram. That push is the *only* thing `channels add telegram` /the
NemoClaw cron bridge buys you, and the operator wants the briefing to stay
Slack-only. So skipping `channels add` costs nothing here — you still get a
fully two-way bot — and it lets you avoid the rebuild. The rebuild is **all
risk, no benefit** for this goal.

## 3. The actual goal

A **conversational, inbound** Telegram bot for Gandalf: Charlie DMs the bot, the
bot replies. (Outbound Telegram cron delivery is explicitly out of scope.) That
means the real requirement is: **`platforms.telegram` present in the live
`/sandbox/.hermes/config.yaml`, with the bot token available in the sandbox
`.env`, integrity hash recomputed, gateway restarted — mirroring exactly how
`platforms.slack` inbound is working today. No rebuild required.**

---

## 4. Do this — Phase A: DIAGNOSE (read-only, establish ground truth)

Do not change anything yet. Confirm the current reality on the Spark, because
this analysis is inferred from runlogs and the live state may differ.

1. **Versions** — have they moved since 06-18?
   `nemohermes --version`, `openshell --version`, and the Hermes version inside
   the sandbox. If Hermes/NemoHermes has been upgraded, the generator may now
   subscribe platforms on `channels add` — which would change the plan. Record.

2. **Is Slack inbound actually live, and how?** Inspect the running gateway's
   config:
   ```bash
   CONTAINER=$(<however ops/_lib.sh resolves gandalf_container>)
   docker exec "$CONTAINER" sed -n '1,200p' /sandbox/.hermes/config.yaml
   ```
   - Does a `platforms.slack` (or `platforms:` with slack) block exist? Capture
     its exact shape — token reference style (`openshell:resolve:env:...`? env
     var? inline?), allowed-users field, any `enabled:` flags.
   - Confirm `platforms.api_server` is there too.
   - Note whether `platforms.telegram` already exists (the report saw
     `NEMOCLAW_TELEGRAM_CONFIG_B64=e30=`, i.e. empty — but check config.yaml).

3. **The integrity-hash mechanism.** Look at
   `cat /etc/nemoclaw/hermes.config-hash` and confirm it holds sha256 of both
   `/sandbox/.hermes/config.yaml` and `/sandbox/.hermes/.env`. This is the file
   `post-rebuild.sh` section 2d already knows how to recompute — that same logic
   is what makes a config.yaml edit launchable.

4. **Find how `platforms.slack` got injected.** Search for the un-committed fix
   so we can make it (and telegram) reproducible:
   `grep -rn "platforms" ~/gandalf-bringup/ ~/.hermes/ 2>/dev/null`, shell
   history, any patch scripts. Determine: **does anything re-inject
   `platforms.slack` after a rebuild, or is it currently a one-off manual edit
   that a rebuild would wipe?** (Strong prior: it's a one-off and NOT
   rebuild-safe.)

5. **Confirm the token path Hermes' telegram adapter expects.** Reconcile
   against the live Hermes Telegram doc
   (<https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram>):
   does the in-process adapter read `TELEGRAM_BOT_TOKEN` from the sandbox `.env`,
   or only from a `platforms.telegram` config block, or both? This decides
   whether the token goes in `/sandbox/.hermes/.env` (via `post-rebuild.sh`
   `EXTRA_ENV_KEYS`), in config.yaml, or both.

**Report Phase A findings back to the operator before Phase B.** If Phase A
contradicts this analysis (e.g. versions moved and `channels add` now adds
`platforms.telegram`), say so and propose the simpler path instead.

## 5. Do this — Phase B: ENABLE inbound Telegram (no rebuild), assuming Phase A confirms the analysis

Mirror the live Slack inbound setup exactly, for telegram. **No `channels add`,
no rebuild.** Keep a snapshot in hand (`pre-telegram` v14 exists; take a fresh
one if state moved).

1. **Put the bot token where the adapter reads it.** Most likely
   `/sandbox/.hermes/.env`. Add `TELEGRAM_BOT_TOKEN` (and `TELEGRAM_ALLOWED_USERS`
   if the adapter reads it from env) to `post-rebuild.sh`'s `EXTRA_ENV_KEYS` list
   so it's synced from `~/.hermes/.env` and survives future rebuilds, then run
   the sync + rehash path. (Token values: in `~/.hermes/.env` already.)

2. **Inject `platforms.telegram` into `/sandbox/.hermes/config.yaml`**, shaped
   identically to the `platforms.slack` block you captured in Phase A (same
   token-reference convention, allowed-users = Charlie's numeric ID
   `8730021403`, enabled). Back up config.yaml first.

3. **Recompute `/etc/nemoclaw/hermes.config-hash`** for both config.yaml and
   .env (reuse the exact logic in `post-rebuild.sh` section 2d). The gateway will
   refuse to start otherwise.

4. **Restart only the gateway** (not a rebuild): use the documented
   recover/restart path (`nemohermes gandalf recover`, or whatever Phase A shows
   actually cycles the gateway process — `start-all.sh` won't if it's "healthy").

## 6. Do this — Phase C: MAKE IT REBUILD-SAFE (so we don't lose this again)

The whole reason inbound is fragile is that the `platforms.*` injection isn't
captured anywhere. Fix that:

- Add a step to `post-rebuild.sh` (or a new `sandbox-scripts/` helper it calls)
  that **re-injects both `platforms.slack` AND `platforms.telegram`** into the
  regenerated config.yaml and re-hashes — so the next rebuild restores inbound
  for both, not neither. This also retroactively protects the Slack inbound bot,
  which is currently one rebuild away from breaking.
- This is the single highest-value piece of hardening here. Do it even if the
  operator later decides to skip Telegram.

## 7. Phase D: SMOKE TEST

- Gateway log shows **both** slack and telegram platforms connected (don't
  accept telegram-up while slack regressed).
- Charlie DMs the bot (`@<bot_username>`) → reply within seconds.
- DM from a non-allowlisted account → denied, not a crash.
- Existing Slack DM/@mention → still works.
- `/sethome` in the Telegram DM if you want a home channel there (optional;
  briefing stays Slack-only).

## 8. Rollback

`nemohermes gandalf snapshot restore pre-telegram` (v14). The egress preset and
`.env` lines are independently reversible. Restore the config.yaml backup from
Phase B step 2 if only the inbound edit needs reverting.

---

## TL;DR for the operator

- The previous session did solid, careful work and correctly found that `.env`
  isn't the credential path. **Not a rabbit hole.**
- But its *next* step (`channels add telegram` → rebuild) would **break the
  working Slack bot and still not give a Telegram chat bot**, because inbound
  chat needs `platforms.<x>` injected into the sandbox config.yaml + a rehash —
  a manual fix that's currently live for Slack but **not captured in any
  script**, so a rebuild wipes it.
- Correct path: **no rebuild.** Mirror the Slack inbound config-injection for
  telegram, then bake both into `post-rebuild.sh` so the next rebuild can't
  silently undo it.
- Start with **Phase A (diagnose, read-only)** and report back before changing
  anything — versions may have moved and changed the picture.
