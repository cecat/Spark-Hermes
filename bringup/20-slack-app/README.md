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

Bot: `chat:write app_mentions:read channels:history channels:read groups:history im:history im:read im:write users:read files:read files:write`
Events: `app_mention message.im message.channels message.groups`
Socket Mode: on.

Known scope gap: this manifest does NOT include `groups:read` (private channel enumeration) or `channels:join` (bot self-invite). Add them if you need either; you'll have to reinstall the app to the workspace after editing the manifest.
