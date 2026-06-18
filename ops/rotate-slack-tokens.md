# Rotate Slack tokens

When to do this:
- Token was leaked or you suspect compromise.
- Token was revoked in Slack (admin policy, ownership change, etc.).
- You're rotating on a schedule.

## Steps

1. **Regenerate the bot token.** In Slack app settings (api.slack.com/apps → Gandalf → OAuth & Permissions), click **Reinstall to Workspace**. This issues a fresh `xoxb-...` and invalidates the old one.

2. **Regenerate the app-level token.** Basic Information → App-Level Tokens → delete the old `socket` token → Generate Token and Scopes → name `socket`, scope `connections:write` → Generate. Copy the new `xapp-...`.

3. **Update `~/.hermes/.env`** with both new values:
   ```
   chmod 600 ~/.hermes/.env
   nano ~/.hermes/.env
   # Replace SLACK_BOT_TOKEN and SLACK_APP_TOKEN values
   ```

4. **Rebuild the sandbox.** The tokens are baked into the OpenShell credential proxy at sandbox build time:
   ```
   bash snapshot.sh pre-token-rotation
   nemohermes gandalf channels add slack    # re-registers with new tokens from .env
   nemohermes gandalf rebuild --yes         # picks up the new credentials
   ```
   This takes ~3-5 minutes (full base image + sandbox rebuild).

5. **Verify:**
   ```
   bash status.sh
   ```
   The Slack section should report the bot identity correctly.

## What does NOT need to change

- Slack manifest (`bringup/20-slack-app/manifest.yaml`) — unchanged unless you're also changing scopes.
- Channel IDs (`SLACK_HOME_CHANNEL`, `SLACK_ALLOWED_CHANNELS`) — unchanged.
- The bot's `/invite`d state in channels — survives token rotation.

## If something breaks

You took a snapshot in step 4. Roll back:
```
nemohermes gandalf snapshot restore pre-token-rotation
```
