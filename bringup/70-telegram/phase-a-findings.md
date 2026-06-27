# Telegram bring-up — Phase A findings (read-only diagnosis)

**Date:** 2026-06-27
**Operator:** catlett (on `spark-960b`, repo at `510e13b`)
**Author:** Claude Code session on the Spark, following the Phase A directions
in `bringup/70-telegram/NEXT-STEPS-FOR-CLAUDE-CODE.md`.

> **Status: STOPPED before any state change.** This file is the report.
> No `channels add`, no rebuild, no config.yaml edit, no rehash, no gateway
> cycle. All findings below are from inspection only.

---

## TL;DR

The NEXT-STEPS file's central premise — that Slack inbound works today because
someone hand-injected `platforms.slack` into `/sandbox/.hermes/config.yaml` +
recomputed the integrity hash, and that this fix is **not rebuild-safe** — is
**not what the live state shows.** There is no `platforms.slack` block in the
live config.yaml. The integrity hash matches the original file byte-for-byte
(no manual edit). Yet Slack Socket Mode is connected and DM-able.

The actual mechanism is NemoClaw env-var injection (`NEMOCLAW_MESSAGING_*_B64`
+ `openshell:resolve:env:...` token placeholders) which the Hermes NemoClaw
plugin reads at startup to spawn platform adapters. This **is** rebuild-safe —
NemoClaw re-bakes those env vars at every sandbox start.

So the case for "no rebuild, hand-inject platforms.telegram into config.yaml"
collapses. Recommended Phase B is the boring path the NEXT-STEPS file warned
against: snapshot, then `nemohermes gandalf channels add telegram`, then
`ops/post-rebuild.sh`, then verify **both** slack and telegram come up. With
the (small) caveat noted at the end.

---

## Phase A questions and evidence

### Q1 — Versions: have they moved since 2026-06-18?

**No.** Identical to the handoff:

```
nemohermes v0.1.0
openshell 0.0.44
Agent: Hermes Agent v2026.5.16
```

(via `nemohermes --version`, `openshell --version`, `nemohermes gandalf status`).

So we can't blame "the generator changed and now does the right thing." Whatever
behavior is in play today was in play 9 days ago.

### Q2 — Is `platforms.slack` in the live config.yaml? Anything `platforms.telegram`?

**No to both.** Only `platforms.api_server` is present:

```yaml
platforms:
  api_server:
    enabled: true
    extra:
      port: 18642
      host: 127.0.0.1
```

There **are** top-level `slack:` and `telegram:` blocks elsewhere in
config.yaml — but they're per-platform *defaults* (e.g. `slack.require_mention:
true`, `telegram.reactions: false`, `telegram.allowed_chats: ""`). They're not
platform-enablers. Search confirms `platforms:` appears once in the file, with
only `api_server` under it.

Captured via:

```bash
CON=$(docker ps --format '{{.Names}}' | grep ^openshell-gandalf-)
docker exec -u root "$CON" cat /sandbox/.hermes/config.yaml
```

### Q3 — Yet Slack inbound is live. How?

The gateway startup log for the most recent cold boot of the slack adapter
(2026-06-19 22:24, the sethome-suppress restart) is the smoking gun:

```
INFO gateway.run: Connecting to api_server...
INFO gateway.run: ✓ api_server connected
INFO gateway.run: Connecting to slack...
INFO gateway.platforms.slack: [Slack] Using proxy for Slack transport: http://10.200.0.1:3128
INFO gateway.platforms.slack: [Slack] Authenticated as @gandalf in workspace
                              Trillion Parameter Consortium (team: T05H0N7A6HM)
INFO gateway.platforms.slack: [Slack] Socket Mode connected (1 workspace(s))
INFO gateway.run: ✓ slack connected
INFO gateway.run: Gateway running with 2 platform(s)
```

Live behavior confirms it's still running:

```
[ocsf] NET:UPGRADE wss-primary.slack.com:443
[ocsf] HTTP:GET ... users.conversations [policy:slack engine:l7]
```

So Hermes is starting a Slack adapter for a platform that's NOT in
`config.yaml`. The trigger is in the gateway process environment:

```
NEMOCLAW_MESSAGING_CHANNELS_B64    → ["slack"]
NEMOCLAW_MESSAGING_ALLOWED_IDS_B64 → {"slack":["U05H8JM8NFQ"]}
NEMOCLAW_SLACK_CONFIG_B64           → {"allowedChannels":["C0BAV5A4C7R"]}
SLACK_BOT_TOKEN=openshell:resolve:env:v366992711826075384_SLACK_BOT_TOKEN
SLACK_APP_TOKEN=openshell:resolve:env:v366992711826075384_SLACK_APP_TOKEN
HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=1     # Telegram-aware even though disabled
NEMOCLAW_TELEGRAM_CONFIG_B64=e30=          # base64("{}")
NEMOCLAW_WECHAT_CONFIG_B64=e30=
NEMOCLAW_DISCORD_GUILDS_B64=e30=
```

These come from NemoClaw at sandbox-start time, not from `~/.hermes/.env`.
The Hermes `nemoclaw` plugin (enabled at the bottom of config.yaml:
`plugins.enabled: [nemoclaw]`) reads `NEMOCLAW_MESSAGING_CHANNELS_B64` and
spins up the matching `platforms.*` adapters dynamically — bypassing the
config.yaml `platforms:` section entirely. The L7 proxy resolves the
`openshell:resolve:env:...` placeholders to the real Slack tokens at the
network boundary, so the sandbox process never sees the raw secret.

**Net:** `nemohermes gandalf channels add slack` (run during onboard) wired
both outbound delivery **and** inbound chat for Slack. It's been working that
way the whole time. The HANDOFF-2026-06-18 note that "channels add doesn't
add `platforms.slack` ... inbound won't work" was an inference from reading
`hermes-config.ts` source while inbound was still deferred — it turned out to
be wrong once the gateway came up post-rebuild.

### Q4 — Integrity hash mechanism

```
$ docker exec -u root "$CON" cat /etc/nemoclaw/hermes.config-hash
e4677b7e15169f8f464c3e8f37bb5f6ed4f5e37e40fb8d773349d5dde0b6bc95  /sandbox/.hermes/config.yaml
a793eb3af49bda75db4305e4b1a7febdc611ebab4cd22b2d4fa81e7de2e789f5  /sandbox/.hermes/.env

$ docker exec -u root "$CON" sha256sum /sandbox/.hermes/config.yaml /sandbox/.hermes/.env
e4677b7e15169f8f464c3e8f37bb5f6ed4f5e37e40fb8d773349d5dde0b6bc95  /sandbox/.hermes/config.yaml
a793eb3af49bda75db4305e4b1a7febdc611ebab4cd22b2d4fa81e7de2e789f5  /sandbox/.hermes/.env
```

Hashes match exactly. Confirms:
- Editing config.yaml or .env without recomputing this file will refuse to
  launch the gateway (the mechanism IS real, and IS the supported path for
  edits that go through it).
- **No one has hand-edited config.yaml or `.env` since NemoClaw last baked
  them.** Whatever made Slack inbound work, it wasn't this path.

### Q5 — Where does the Hermes Telegram adapter read its token?

From the live Hermes docs
(<https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram>):

> "Add the following to `~/.hermes/.env`: `TELEGRAM_BOT_TOKEN=...`"
>
> "Use `platforms.telegram.extra`, not `telegram.extra` ... only the
> `platforms.<name>.extra` form is deep-merged into the platform config."
>
> "The presence of the token triggers initialization."

So Hermes-native: **token from environment** (sandbox `.env` or however the env
gets populated), `platforms.telegram.extra` only for per-adapter tuning, no
explicit enable switch — env-var presence is the switch.

In *this* deployment, NemoClaw is the wrapper, so the analogous path is what
Slack uses today: `channels add telegram` populates
`NEMOCLAW_MESSAGING_CHANNELS_B64 += "telegram"`, sets
`TELEGRAM_BOT_TOKEN=openshell:resolve:env:...` in the gateway env, and the
NemoClaw plugin starts the adapter at boot. That's the **expected** behavior;
it's not yet observed for Telegram in this sandbox.

---

## Contradictions with `NEXT-STEPS-FOR-CLAUDE-CODE.md`

| NEXT-STEPS claim | Phase A finding |
|---|---|
| "`channels add slack` did NOT add `platforms.slack`" | Correct that it didn't add it to **config.yaml**. Incorrect that the adapter therefore isn't running — it IS running, started by the `nemoclaw` plugin from `NEMOCLAW_MESSAGING_CHANNELS_B64`. |
| "Inbound was turned on by hand between 06-18 and 06-21 by injecting `platforms.slack` into config.yaml + rehashing" | No evidence of this. `config.yaml` has no `platforms.slack`. Hash matches the unedited file. Sethome-suppress patch on 06-19 cycled the gateway → NemoClaw env was already in place → Slack came up on its own. |
| "That manual injection isn't rebuild-safe — a rebuild WIPES Slack inbound" | The hypothetical injection doesn't exist, so there's nothing to wipe. Slack inbound is governed by NemoClaw env, which IS rebuilt on rebuild. Past rebuilds (multiple, per `snapshot list` v3..v14) didn't break it. |
| "`channels add telegram` will rebuild + break Slack + still not give Telegram chat → all risk, no benefit" | The "break Slack" and "no Telegram chat" parts don't hold up. The rebuild is real, but its purpose (re-bake NemoClaw envs to include telegram) is exactly what enables the adapter. |
| "Correct path: hand-inject `platforms.telegram` into config.yaml + rehash, no rebuild" | Would probably *also* work (Hermes natively reads env-vars and merges `platforms.telegram.extra`), but it's the wrong abstraction layer for a NemoClaw-managed sandbox — it bypasses the supported provisioning path and would NOT make the token available (NemoClaw owns token resolution via `openshell:resolve:env:...`, not raw `.env`). And it would itself not be rebuild-safe in a real sense — a rebuild would wipe the hand-edit. |

The NEXT-STEPS file is internally consistent and well-reasoned; it just relied
on two source readings (`hermes-config.ts` saying only api_server is
subscribed; runlog line "both api_server and slack platforms connected") that
together suggested manual injection happened. The third missing piece is the
gateway env — which shows NemoClaw doing the work.

---

## Recommended Phase B (subject to operator approval)

**Goal:** conversational, inbound Telegram bot — Charlie DMs the bot, the bot
replies. Augments Slack, doesn't replace it. No briefing duplication.

**Approach:** mirror exactly how Slack got here. Use the supported NemoClaw
provisioning path. Accept the rebuild — it's how this stack works.

Steps:

1. **Snapshot.** `pre-telegram` (v14, 2026-06-27 11:44Z) exists. Take a fresh
   one if anything material has happened since (heartbeat / cron writes don't
   count). Suggest `nemohermes gandalf snapshot create --name pre-telegram-add-v2`.
2. **Dry-run first.** `nemohermes gandalf channels add telegram --dry-run` —
   confirm it reports just "would enable channel 'telegram'" (it did earlier
   today; reconfirm before live run).
3. **Operator confirmation in chat.** Per CLAUDE.md destructive-ops policy.
4. **Live run.** `nemohermes gandalf channels add telegram` — interactive.
   Supply:
   - Bot token: `8504763598:AAEmpYXEBuNkgBr7moV2_gLRX4cbFuGR4fQ`
   - Allowed user: `8730021403`
   Sandbox rebuild follows.
5. **`bash ops/post-rebuild.sh`** — re-apply the `gateway/run.py` sethome
   patch, re-sync `TAVILY_API_KEY` + `HERMES_SUPPRESS_SETHOME_NOTICE` into
   sandbox `.env` + recompute integrity hash, restore sandbox-side scripts,
   re-apply custom egress policies (including `telegram-egress`).
6. **Smoke test — strict gate.** Gateway log must show:
   ```
   ✓ api_server connected
   ✓ slack connected
   ✓ telegram connected
   Gateway running with 3 platform(s)
   ```
   AND a real DM round-trip works on both Slack and Telegram. AND the
   non-allowlisted account is rejected (not crashing).
7. **Failure modes & responses:**
   - If Slack regresses → snapshot restore. We've learned something new and
     should re-examine before retrying.
   - If gateway log shows only 2 platforms (no telegram) → likely cause is
     `NEMOCLAW_TELEGRAM_CONFIG_B64` populated but `TELEGRAM_BOT_TOKEN` not in
     the gateway env (in which case add `TELEGRAM_BOT_TOKEN` and
     `TELEGRAM_ALLOWED_USERS` to `EXTRA_ENV_KEYS` in `post-rebuild.sh`,
     re-run section 2d only — no full rebuild). Quick 5-min follow-up.
   - If anything else weird → stop and report.

**What I would NOT do** (and where I diverge from NEXT-STEPS):

- ❌ Hand-inject `platforms.telegram` into config.yaml + rehash. Bypasses
  NemoClaw, doesn't solve the token-resolution problem, and is fragile.
- ❌ Add a step to `post-rebuild.sh` to re-inject `platforms.slack` into
  config.yaml after every rebuild ("Phase C hardening" in NEXT-STEPS).
  Solves a problem that doesn't exist; would actually *break* the working
  setup (introducing a hand-edited platforms block that conflicts with the
  NemoClaw-managed one).

---

## Open questions for the operator

1. **Has anything changed about the sandbox between 06-21 (tavily pivot) and
   now that I should know about before proceeding?** I've only seen the repo
   commits and the live sandbox state — if you've done shell work on the
   Spark that didn't make it into commits or runlog, that could matter.
2. **Are you comfortable doing the rebuild given the Phase A finding that the
   NEXT-STEPS "rebuild = breaks Slack" risk doesn't hold?** This is the
   biggest decision. The evidence is strong (config.yaml is untouched, slack
   already survived multiple rebuilds), but it's a one-way step.
3. **What gateway log line do you want as the "Telegram is live" gate?**
   The Hermes-native one would be a `gateway.platforms.telegram` info line
   analogous to Slack's "Socket Mode connected." But Telegram doesn't use
   Socket Mode — it long-polls — so the exact wording may differ. I'd
   propose: "`✓ telegram connected`" + `Gateway running with 3 platform(s)`
   in `gateway.log`, AND an outbound TLS connection to `api.telegram.org`
   in the OCSF log within ~30s of restart. Acceptable?
4. **Do you want the post-rebuild verification to assert BOTH slack and
   telegram are up before declaring success, or is "telegram is up" enough?**
   I lean toward the strict joint assertion — fail-loud if Slack regresses,
   even if Telegram works.
5. **Should `bringup/70-telegram/README.md` Part B be rewritten** to reflect
   the actual mechanism (channels add + post-rebuild is the supported path;
   `~/.hermes/.env` is not the credential flow) once Phase B succeeds? My
   `implementation.md` from earlier today partly does this, but it's also
   wrong about the cause (it agreed with what turned out to be the NEXT-STEPS
   misread).
6. **Should I update `implementation.md` and `NEXT-STEPS-FOR-CLAUDE-CODE.md`**
   to mark them as superseded by this Phase A finding, or leave them as a
   historical record of the diagnosis arc? (Recommend: leave both,
   cross-link from each to this file with a banner at the top.)

---

## Files / commands used (Phase A only — all read-only)

```bash
# Versions
nemohermes --version
openshell --version
nemohermes gandalf status

# Live config + integrity hash
CON=$(docker ps --format '{{.Names}}' | grep ^openshell-gandalf-)
docker exec -u root "$CON" cat /sandbox/.hermes/config.yaml
docker exec -u root "$CON" cat /etc/nemoclaw/hermes.config-hash
docker exec -u root "$CON" sha256sum /sandbox/.hermes/config.yaml /sandbox/.hermes/.env

# Gateway env (the smoking gun)
docker exec -u root "$CON" sh -c 'for p in $(pgrep -f "hermes gateway run"); do
  [ -f "/proc/$p/environ" ] && cat "/proc/$p/environ" | tr "\0" "\n" | sort |
    grep -iE "SLACK|TELEGRAM|NEMOCLAW|HERMES|PLATFORM"
done'

# Decode NemoClaw config blobs
echo eyJhbGxvd2VkQ2hhbm5lbHMiOlsiQzBCQVY1QTRDN1IiXX0= | base64 -d  # SLACK_CONFIG
echo WyJzbGFjayJd | base64 -d                                       # MESSAGING_CHANNELS
echo eyJzbGFjayI6WyJVMDVIOEpNOE5GUSJdfQ== | base64 -d               # ALLOWED_IDS
echo e30= | base64 -d                                               # TELEGRAM_CONFIG (empty)

# Live gateway startup log (where Slack inbound actually starts)
docker exec -u root "$CON" sh -c 'grep -nE "platform|slack|telegram|adapter|Connected|api_server" \
  /sandbox/.hermes/logs/gateway.log'

# Live Hermes Telegram docs
WebFetch https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram
```

Nothing on this list mutates state. Safe to re-run.

---

## Rollback if Phase B happens and goes wrong

`nemohermes gandalf snapshot restore pre-telegram` (v14, 2026-06-27 11:44Z).
The `telegram-egress` policy preset and `TELEGRAM_*` lines in `~/.hermes/.env`
are independently reversible (preset can be removed via `policy-remove`; env
lines just edit the file).
