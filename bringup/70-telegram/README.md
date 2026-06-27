# 70 — Telegram (augments Slack)

Add a Telegram bot to Gandalf, running alongside the existing Slack adapter
(both at once; Slack is not touched).

---

## Who does what — read this first

**You (Charlie), in the Telegram app — Part A.** Two steps. A human has to do
these because they happen inside Telegram's app; no Claude Code can do them.
They produce two values: a **bot token** and **your numeric user ID**.

**Claude Code on the Spark — Part B.** Everything else (egress policy, `.env`,
restart, verification). Hand it this file plus the two values from Part A. It
does **not** need to touch the Telegram app.

> Why no host daemon/bridge (unlike Signal): the Telegram adapter runs
> in-process in the gateway and long-polls `api.telegram.org` outbound — same
> shape as Slack's Socket Mode. The only infra is one OpenShell egress preset.

---

## Part A — You, in the Telegram app (~3 min)

1. **Create the bot.** Message **@BotFather** → `/newbot` → display name
   **Gandalf** → username ending in `bot` (e.g. `gandalf_overseer_bot`).
   BotFather replies with a **token** like `123456789:ABCdef...`. Copy it.
   *(Keep it secret; `/revoke` in BotFather if it ever leaks.)*
2. **Get your user ID.** Message **@userinfobot** → it replies with a number
   like `123456789` (this is **not** your @username). Copy it.

Then hand the job to Claude Code on the Spark with a message like:

> "Set up Telegram for Gandalf following `bringup/70-telegram/README.md` Part B.
> Bot token: `123456789:ABCdef...` — my Telegram user ID: `123456789`.
> Don't touch Slack."

That's everything you do. Stop here.

---

## Part B — Claude Code on the Spark (executable runbook)

You are running on `spark-ts` in `~/code/Spark-Hermes` (already `git pull`ed).
The operator gave you `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS` (their
numeric ID) in chat. Do the following, stopping at any failed ✅ gate.

**Alpha software:** before editing `.env`, fetch the live Hermes Telegram doc
and reconcile the env-var names / commands; note any drift in `runlog/`.
<https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram>

```bash
cd ~/code/Spark-Hermes

# 1. Apply the OpenShell egress preset (idempotent; re-applying is a no-op).
bash ops/apply-policies.sh
nemohermes gandalf policy-list | grep -i telegram
#    ✅ GATE 1: telegram-egress shows as loaded. Else stop.

# 2. Add ONLY these two lines to ~/.hermes/.env, using the operator's values.
#    Leave every existing SLACK_* line untouched. Do not echo the token to logs.
#       TELEGRAM_BOT_TOKEN=<operator-provided token>
#       TELEGRAM_ALLOWED_USERS=<operator-provided numeric id>
#    (Template/comments: bringup/secrets.example.env)
chmod 600 ~/.hermes/.env
grep -c '^TELEGRAM_BOT_TOKEN=' ~/.hermes/.env    # expect 1
grep -c '^TELEGRAM_ALLOWED_USERS=' ~/.hermes/.env # expect 1
#    ✅ GATE 2: both vars present exactly once; Slack vars still present. Else stop.

# 3. Restart the stack so the gateway re-reads ~/.hermes/.env.
bash ops/start-all.sh
#    ✅ GATE 3: start-all reports healthy. Else stop and report the failing layer.

# 4. Confirm the adapter connected (alongside Slack, not replacing it).
grep -iE '\[telegram\]|Connected to Telegram' <gateway-log-path>
#    ✅ GATE 4: a Telegram-connected line appears AND Slack is still connected.
```

Then ask the operator to verify from the Telegram app:
- DM the bot (`@<bot_username>`) → expect a reply within seconds.
- Send `/sethome` in that DM (designates it for any future scheduled delivery).
- Confirm a Slack DM/mention still works.

Report which gates passed. Do not enable groups, and do not add any Telegram
cron delivery — the daily briefing stays Slack-only by decision.

---

## Rollback

Remove the two `TELEGRAM_*` lines from `~/.hermes/.env`, then
`bash ops/start-all.sh`. Optionally revoke the token in @BotFather. Nothing here
affects Slack, vLLM, argo, or LiteLLM.
