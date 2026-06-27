# 70 — Telegram bring-up: implementation log (Spark side)

> ⚠️ **Superseded.** The "What still needs to happen" section in this file
> recommended hand-injecting `platforms.telegram` into config.yaml + rehash to
> avoid a rebuild. Phase A diagnosis later that day showed that premise was
> wrong: Slack inbound runs via the NemoClaw env path
> (`NEMOCLAW_MESSAGING_CHANNELS_B64` + `openshell:resolve:env:…` placeholders),
> not via a hand-edited config.yaml. The supported path for adding Telegram is
> `nemohermes gandalf channels add telegram` + `ops/post-rebuild.sh` — a
> rebuild, but a rebuild-safe one. **Read
> [`phase-a-findings.md`](phase-a-findings.md) for the corrected mechanism
> before acting on anything below.**



**Date:** 2026-06-27
**Operator:** catlett (on `spark-960b`, repo at `bc30536`)
**Goal:** follow `bringup/70-telegram/README.md` Step 4 onward — apply egress,
load credentials, restart, smoke-test the Telegram adapter alongside Slack.
**Outcome:** stopped before flipping the bit. Egress + repo-side state are in
place and committed; the actual adapter-enable step turned out to be a sandbox
**rebuild** (`channels add telegram`), not a gateway re-read. A pre-rebuild
snapshot (`pre-telegram`, v14) was taken; next step is operator review of the
README correction below before proceeding.

---

## What was done

### 1. Egress policy applied ✅
`bash ops/apply-policies.sh` — `telegram-egress.yaml` already in the repo, was
not yet loaded in the sandbox. Submitted as **policy version 12**:

```
[telegram-egress] Endpoints that would be opened: api.telegram.org
✓ Policy version 12 submitted (hash: 592c889b46a9)
✓ Policy version 12 loaded (active version: 12)
```

`policy-list` confirms both the custom `telegram-egress` preset and the built-in
`telegram` preset are now active. All other previously-loaded presets stayed
unchanged.

### 2. `~/.hermes/.env` updated ✅
Appended a labeled block (kept all `SLACK_*` lines untouched, restored
`chmod 600`):

```env
# Telegram — augments Slack; both adapters run concurrently. Adapter long-polls
# api.telegram.org in-process (no host daemon). Egress: telegram-egress preset.
# Setup: bringup/70-telegram/README.md. Added 2026-06-27.
TELEGRAM_BOT_TOKEN=<BOT_TOKEN>
TELEGRAM_ALLOWED_USERS=<ALLOWED_USER_ID>
# (real values live in ~/.hermes/.env on the Spark host; never commit them)
```

### 3. Stack health-checked ✅
`bash ops/start-all.sh` — all layers reported healthy on the first pass. The
script is idempotent and did **not** restart the gateway (it only restarts
broken layers).

### 4. Pre-rebuild snapshot ✅
`nemohermes gandalf snapshot create --name pre-telegram` — taken as v14
(`2026-06-27T11-44-21-092Z`). Worth noting: the first run printed
`Snapshot failed. Failed files: runtime/state.db` (WAL contention while the
gateway is live writing the response store), but a re-run reported the snapshot
already existed under that name. `snapshot list` shows v14 sitting at the head
of the stack. **Restore command if needed:**
`nemohermes gandalf snapshot restore pre-telegram`.

### 5. Stopped before the rebuild step ✋
The README's Step 4c (`bash ops/start-all.sh` to re-read env) is **not enough**
to enable the adapter in this NemoClaw-mediated deployment — see the roadblock
below. The actual enable step (`nemohermes gandalf channels add telegram`)
triggers a sandbox rebuild and was not run; awaiting operator confirmation.

---

## Roadblocks / deviations from the README

### Roadblock A — gateway env is NOT raw env from `~/.hermes/.env`

The README models the gateway as a normal process that re-reads
`~/.hermes/.env` on restart. In this deployment that's not how messaging
credentials flow.

**Evidence.** Inspecting the live gateway process env inside the sandbox
container (PID 197):

```
SLACK_APP_TOKEN=openshell:resolve:env:v366992711826075384_SLACK_APP_TOKEN
SLACK_BOT_TOKEN=openshell:resolve:env:v366992711826075384_SLACK_BOT_TOKEN
SLACK_ALLOWED_USERS=U05H8JM8NFQ
SLACK_ALLOWED_CHANNELS=C0BAV5A4C7R
HERMES_SUPPRESS_SETHOME_NOTICE=1
TAVILY_API_KEY=<TAVILY_KEY>
NEMOCLAW_SLACK_CONFIG_B64=eyJhbGxvd2VkQ2hhbm5lbHMiOlsiQzBCQVY1QTRDN1IiXX0=
NEMOCLAW_TELEGRAM_CONFIG_B64=e30=        # ← base64 of "{}", i.e. empty
HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=1
```

Notice:
- Slack tokens are **rewritten** to `openshell:resolve:env:...` placeholders.
  The raw `xoxb-` / `xapp-` strings from `~/.hermes/.env` are not present in
  the sandbox process — NemoClaw is intercepting credential access at the
  boundary.
- `NEMOCLAW_TELEGRAM_CONFIG_B64=e30=` is base64 of `{}` — Telegram is
  registered as a known channel but with **empty config**, i.e. disabled.
- `TELEGRAM_BOT_TOKEN` / `TELEGRAM_ALLOWED_USERS` from `~/.hermes/.env`
  **do not appear** in the gateway env. The host-side `.env` is not what gets
  the adapter to start.

Cross-check: `/sandbox/.hermes/.env` only contains a small allowlist of keys
(none of `SLACK_*` or `TELEGRAM_*`). `ops/post-rebuild.sh` documents this
explicitly — it manually copies `HERMES_SUPPRESS_SETHOME_NOTICE` and
`TAVILY_API_KEY` into the sandbox `.env` (and re-hashes
`/etc/nemoclaw/hermes.config-hash`) because *"NemoClaw bakes that file from a
limited allowlist of keys"*.

**The actual enable mechanism.** `nemohermes gandalf` exposes a `channels`
subtree (not documented in the README):

```
nemohermes <name> channels list                List supported messaging channels
nemohermes <name> channels add <channel>       Save messaging channel credentials and rebuild
nemohermes <name> channels remove <channel>    Clear messaging channel credentials and rebuild
nemohermes <name> channels stop <channel>      Disable channel without wiping credentials
nemohermes <name> channels start <channel>     Re-enable a stopped messaging channel
```

`nemohermes gandalf channels add telegram --dry-run` confirms it would
"enable channel 'telegram' for 'gandalf'". The non-dry-run form is **interactive**
(prompts for the token + allowed users, stores them through NemoClaw, then
queues a sandbox **rebuild**).

That matches the Slack baseline: Slack works today because someone ran
`channels add slack` at onboard time, not because `~/.hermes/.env` is loaded.
`SLACK_HOME_CHANNEL` is the one Slack value that *is* in `~/.hermes/.env`
without appearing in the gateway env — suggesting that env line, too, is
inert in this deployment, and Slack home is set via `/sethome` in-app instead.

**Implication for `~/.hermes/.env`.** The two TELEGRAM_* lines I added are
harmless but probably also inert. Either:
- leave them as documentation / belt-and-suspenders, in case a future Hermes
  version reads them directly; or
- remove them once `channels add telegram` is run and we confirm the gateway
  picks up its config from NemoClaw's store.

Recommend leaving them for now, with the comment block already in place
explaining why.

### Roadblock B — `start-all.sh` doesn't force a gateway restart

`start-all.sh` is correctly idempotent — `ensure_hermes_gateway` only triggers
`nemohermes gandalf recover` when the gateway is *unhealthy*. After editing
`~/.hermes/.env`, running `start-all.sh` is a no-op and the (hypothetically
loaded) env never gets re-read. `nemohermes gandalf recover` is also a probe
that short-circuits if the gateway answers ("`Probe complete: Hermes Agent
gateway is running`") — it doesn't unconditionally restart.

This is largely moot given Roadblock A (env editing is not the mechanism), but
worth flagging in the README so the next person doesn't expect a restart to be
the missing link.

### Roadblock C — snapshot success message is misleading

The first `snapshot create` printed `Snapshot failed. Failed files:
runtime/state.db` but the snapshot was committed anyway (visible as v14 in
`snapshot list`). Subsequent `--name pre-telegram` invocation rejected as
duplicate. The WAL contention on `runtime/state.db` is expected when the
gateway is live (SQLite WAL is held by PID 197). Not a real failure, just
unclear UX.

### Roadblock D — no `confirm before risky action` in README

Per top-level instructions ("for actions visible to others or that affect
shared state, by default confirm before proceeding"), the sandbox rebuild
implied by `channels add` is exactly such an action. Stopping here for
operator approval before running it is the right move; the README should
explicitly call this out as a one-time interactive step rather than wrapping
it implicitly in "restart the stack".

---

## What still needs to happen to finish bring-up

1. **Operator approval to rebuild the sandbox.** Slack creds, kanban DB,
   memories, plans, and the post-rebuild patches (`gateway/run.py`
   `HERMES_SUPPRESS_SETHOME_NOTICE` patch, TAVILY env sync) are expected to
   survive because `ops/post-rebuild.sh` exists precisely to restore them
   after a rebuild — but this is the first time we'll exercise that path
   post-Tavily, so a careful re-verification is warranted.

2. **Run `nemohermes gandalf channels add telegram`** (interactive). Supply:
   - Bot token: `<BOT_TOKEN>` (real value in `~/.hermes/.env`)
   - Allowed user: `<ALLOWED_USER_ID>` (real value in `~/.hermes/.env`)

3. **Run `bash ops/post-rebuild.sh`** to:
   - Re-apply the `gateway/run.py` sethome-notice patch
   - Re-sync `HERMES_SUPPRESS_SETHOME_NOTICE` and `TAVILY_API_KEY` into the
     sandbox `.env` and rehash `/etc/nemoclaw/hermes.config-hash`
   - Restore sandbox-side scripts
   - Re-apply all custom egress policies (telegram-egress will go back in)

4. **Smoke test the README's Step 5 checklist:**
   - `grep -iE '\[telegram\]|Connected to Telegram' <gateway.log>` — adapter up
   - DM the bot from the allowlisted account — round-trip works
   - DM from a different account — denied (not a crash)
   - Slack DM/mention still works — augmentation, not replacement
   - `/sethome` in the bot DM — cron home set

5. **Rollback path** if step 4 fails: `nemohermes gandalf snapshot restore
   pre-telegram` (v14, taken today). The egress preset and `.env` lines are
   reversible separately.

---

## Recommended README corrections (to fold in later)

- Rename Step 4 to make the **rebuild** explicit. Replace "Add the Telegram
  block to `~/.hermes/.env` ... restart the stack" with:
  1. Apply egress (`bash ops/apply-policies.sh`)
  2. Snapshot (`nemohermes gandalf snapshot create --name pre-telegram`)
  3. Register the channel: `nemohermes gandalf channels add telegram` —
     interactive; supply token + allowed user IDs. **This rebuilds the
     sandbox.**
  4. Run `bash ops/post-rebuild.sh` to restore patches / sandbox-side env /
     scripts / custom policies.
  5. Health-check with `bash ops/start-all.sh`.
- Note that `~/.hermes/.env`'s `TELEGRAM_*` and `SLACK_*` lines are **not**
  what the gateway reads — they're convenience documentation. The real
  credential store is NemoClaw's per-channel config (base64-encoded into
  `NEMOCLAW_*_CONFIG_B64` and `openshell:resolve:env:...` placeholders).
- Document the `nemohermes gandalf channels` subtree alongside `channels list`,
  which is already mentioned.
- Mention the misleading `Snapshot failed. Failed files: runtime/state.db`
  message — it's not a failure; confirm via `snapshot list`.

---

## Files touched on the Spark this session

- `/home/catlett/.hermes/.env` — appended TELEGRAM_* block, restored 0600.
- OpenShell policy v12 in the gandalf sandbox — `telegram-egress` loaded.
- Snapshot `pre-telegram` (v14) in `/home/catlett/.nemoclaw/rebuild-backups/gandalf/`.
- `bringup/70-telegram/implementation.md` — this file.

Nothing in the repo other than this file was modified. Slack was not touched.
