# 70 — Telegram (augments Slack)

Adds **Telegram** to Gandalf alongside the existing Slack adapter. Both run
concurrently — this does **not** touch the Slack setup.

Telegram is Hermes's most deeply supported messaging platform (richest adapter:
voice transcription, TTS voice bubbles, group mention controls, etc.) and the
**simplest to operate in this deployment**.

## Why this is simpler than Slack or Signal here

The Telegram adapter runs **in-process inside the gateway** and long-polls
`api.telegram.org` (outbound HTTPS — same shape as Slack's Socket Mode). So
unlike Signal there is **no host daemon and no socat bridge**: the only
deployment infra is one OpenShell egress preset. And a Telegram **bot is its own
identity** (`@your_bot_username`) by construction — no phone number to source,
which is exactly the you-vs-Gandalf separation you wanted.

```
your phone (Telegram)  ─DM→  api.telegram.org  ←long-poll─  Hermes Telegram adapter
                                                            (in the gandalf sandbox)
```

## Where each step runs (Mac ↔ Spark)

This repo is edited on the **MacBook**; Hermes runs on the **DGX Spark**.

| Step | Runs on |
|---|---|
| 1. Create bot via @BotFather | Your Telegram app (phone/desktop) |
| 2. Get your numeric user ID | Your Telegram app |
| 3. These repo files (egress preset, env template) | **Mac** → commit → push |
| 4. Pull + apply egress, edit `~/.hermes/.env`, restart | **Spark** (after `git pull`) |
| 5. Smoke test | Your Telegram app + Spark logs |

> **Alpha software** (PLAN rule #1): reconcile the Hermes Telegram env vars and
> commands against the live doc before running on the Spark —
> <https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram>.
> Note any deviation in `runlog/`.

---

## Step 1 — Create the bot (@BotFather, in your Telegram app)

1. Message **@BotFather** → send `/newbot`.
2. Display name: **Gandalf**. Username: must be unique and end in `bot`
   (e.g. `gandalf_overseer_bot`).
3. Copy the **API token** it returns: `123456789:ABCdef...`. Keep it secret
   (`/revoke` in BotFather if it ever leaks).
4. (optional polish) `/setdescription`, `/setuserpic`, and `/setcommands`:
   ```
   help - Show help information
   new - Start a new conversation
   sethome - Set this chat as the home channel
   ```
5. Leave **Group Privacy ON** (the default) — Gandalf is DM-only for now. Only
   disable it (BotFather → `/mybots` → Bot Settings → Group Privacy) if you
   later add the bot to a group.

## Step 2 — Get your numeric user ID (in your Telegram app)

Message **@userinfobot** — it replies instantly with your ID (a number like
`123456789`, **not** your @username). This is the allowlist entry.

## Step 3 — On the Mac: commit & push these repo files

The egress preset (`bringup/50-openshell-policies/telegram-egress.yaml`) and the
updated env template (`bringup/secrets.example.env`) are already in this repo.

```bash
# on the MacBook, in this repo
git add bringup/70-telegram bringup/50-openshell-policies/telegram-egress.yaml bringup/secrets.example.env
git commit -m "Add Telegram adapter phase (augments Slack)"
git push
```

## Step 4 — On the Spark: pull, apply egress, set token, restart

```bash
# on spark-ts
cd ~/code/Spark-Hermes && git pull

# 4a. Approve sandbox egress to api.telegram.org
bash ops/apply-policies.sh
nemohermes gandalf policy-list | grep -i telegram     # confirm telegram-egress loaded

# 4b. Add the Telegram block to ~/.hermes/.env (template: bringup/secrets.example.env).
#     Leave every SLACK_* line untouched. Fill in real values:
#       TELEGRAM_BOT_TOKEN=123456789:ABCdef...
#       TELEGRAM_ALLOWED_USERS=<your numeric id from Step 2>
#     Then:
chmod 600 ~/.hermes/.env

# 4c. Restart the stack so the gateway re-reads ~/.hermes/.env
bash ops/start-all.sh
```

> **Access control:** without `TELEGRAM_ALLOWED_USERS`, the gateway denies all
> Telegram messages by default (the adapter has terminal access). Your numeric
> ID is the allowlist; the bot's own identity is the token.

## Step 5 — Smoke test ✅

1. **Adapter up:** gateway log shows the Telegram adapter connecting alongside
   Slack:
   ```bash
   grep -iE '\[telegram\]|Connected to Telegram' <gateway.log>
   ```
2. **DM works:** in Telegram, open your bot (`@your_bot_username`) and send
   `hi` → expect a reply within seconds.
3. **Allowlist holds:** a message from a different account is ignored; the log
   shows a denial, not a crash.
4. **Slack still works:** send a Slack DM/mention — augmentation, not replacement.
5. **Home channel:** send `/sethome` in the bot DM so scheduled jobs can deliver
   there.

If all five pass, Telegram is live next to Slack.

---

## Optional — also deliver the daily briefing to Telegram

The existing `daily-briefing` cron (in `~/.hermes/config.yaml`) delivers to
Slack. To **also** send it to Telegram, add a second job targeting the chat you
ran `/sethome` in, then `bash ops/apply-cron.sh`:

```yaml
    - name: daily-briefing-telegram
      schedule: "7 13 * * *"
      deliver: "telegram:home"      # verify the telegram delivery syntax in the cron docs
      prompt: |
        (same prompt as daily-briefing)
```

Confirm the exact `telegram:` delivery-target syntax against the Hermes cron
docs before applying — the `slack:<id>` form is what's proven in this repo.

---

## Rollback

```bash
# on the Spark: remove the TELEGRAM_* block from ~/.hermes/.env, then
bash ops/start-all.sh
# (optional) revoke the bot token in @BotFather
```

Nothing here touches Slack, vLLM, argo, or LiteLLM — removing the env block (and
optionally the egress preset) fully reverts.
