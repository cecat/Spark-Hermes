# 20 — Slack app

Creates the Slack app that Gandalf uses. ~5 minutes of clicking.

## Steps

1. Go to https://api.slack.com/apps → **Create New App** → **From a manifest**.
2. Pick the workspace Gandalf will live in.
3. On the manifest box, switch to the **YAML** tab and paste the contents of [`manifest.yaml`](manifest.yaml). (JSON form is at [`manifest.json`](manifest.json) if you need it.)
4. Next → review → **Create**.
5. **App-Level Token** (Socket Mode):
   - **Basic Information → App-Level Tokens → Generate Token and Scopes**
   - Name: `socket`, scope `connections:write` → **Generate**
   - Copy the `xapp-…` value. *Shown only once.* → save as `SLACK_APP_TOKEN`.
6. **Bot Token**:
   - **OAuth & Permissions → Install to Workspace → Allow**
   - Copy the **Bot User OAuth Token** (`xoxb-…`) → save as `SLACK_BOT_TOKEN`.
7. Create the home channel in Slack (e.g. `#agent-gandalf`). Note the **Channel ID** (`C…` — find it in the channel's About panel). Save as `SLACK_HOME_CHANNEL`.
8. Find your own Slack member ID (your profile → ⋮ → Copy member ID). Save as `SLACK_ALLOWED_USERS`.

## Put them in `~/.hermes/.env`

Template at [`../secrets.example.env`](../secrets.example.env). Final file:
```
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_HOME_CHANNEL=C...
SLACK_ALLOWED_USERS=U...
SLACK_ALLOWED_CHANNELS=C...   # same as home channel for single-channel use
```
Then `chmod 600 ~/.hermes/.env`.

## After Gandalf is running

The bot can't post to the channel until you invite it. In Slack:
```
/invite @Gandalf
```
in your home channel. This is the only Slack step that's not automatable.

## Scopes the manifest includes

Bot: `chat:write commands app_mentions:read channels:history channels:read groups:history groups:read im:history im:read im:write users:read files:read files:write reactions:read`
Events: `app_mention message.im message.channels message.groups`
Socket Mode: on.
Slash commands: `/hermes` (dispatcher for all Hermes subcommands — `sethome`, `new`, `status`, `model`, etc.; see the full list inside the sandbox with `/hermes help`).

Known scope gap: this manifest does NOT include `channels:join` (bot self-invite). Add it if you want to skip the manual `/invite @Gandalf` step in new channels.

---

## Day 2 — updating an already-installed app from the manifest

If you edit `manifest.yaml` and need to push the change to your existing Slack app (e.g. to add a slash command), there is no need to recreate the app — Slack lets you replace the manifest in place:

1. Go to https://api.slack.com/apps → pick your **Gandalf** app.
2. Left sidebar: **App Manifest**.
3. Paste the new `manifest.yaml` contents over what's there → **Save Changes**.
4. Slack shows a yellow banner listing what changed (new scopes, new slash commands, etc.) and prompts **Reinstall to Workspace**. Click it → **Allow**.
5. **Tokens unchanged:** `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` are not rotated by a manifest update + reinstall. Don't touch `~/.hermes/.env`.
6. Slack starts routing the new slash commands to the existing Socket Mode connection immediately — no Gandalf restart required.

### Why slash commands need this step

Hermes's `/hermes`, `/sethome`, `/btw`, `/model`, etc. are all implemented inside the gateway (`/opt/hermes/gateway/run.py` + `hermes_cli/commands.py`). But **Slack doesn't know any of them exist unless the app manifest declares them.** Without the declaration, typing `/hermes` in Slack shows "Running /hermes..." for a few seconds and then nothing — Slack acknowledges the command was typed but has no app to route it to. This caused the "no home channel" notice to fire indefinitely on every DM for two days because `/hermes sethome` literally couldn't reach the gateway.

We declare just `/hermes` (not all 53 subcommands individually) because Hermes's Slack adapter rewrites `/hermes <sub>` → `/<sub>` internally and dispatches from there. One Slack-side registration covers the whole Hermes command surface.

### How to know it worked

In your Slack DM with Gandalf, type `/` — Slack's command picker should now show `/hermes` with the description "Send a command or question to Gandalf". Then `/hermes help` should return the Hermes command list within a few seconds (not "Running /hermes...").
