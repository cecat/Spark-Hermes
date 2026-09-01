# Runbook — register a second Slack app (Phase E / tutorial decision D2)

Verified against the live deployment 2026-08-31. Staging planes run OpenClaw
**2026.7.1**; the old live gateway runs **2026.6.11**. The `accounts` /
`bindings[].match.accountId` schema is confirmed present in 2026.7.1's shipped
type definitions, so the tutorial's §I.1 recommendation is executable here.

Goal: give cecat and luoji each their own Slack bot identity, so an agent is
never @-mentioned by a handle its `IDENTITY.md` says is not its name.

---

## 0. What exists today (do not re-derive)

Current single app, workspace **Trillion Parameter Consortium**, bot user
`chattpc`. One app serves both agents; routing is by channel:

| Agent | Bound channels |
|---|---|
| cecat | 1 channel |
| luoji | 3 channels |

Live bot scopes, read from the token (authoritative — the tutorial's list is
incomplete):

```
app_mentions:read   channels:history   channels:read      chat:write
files:read          files:write        groups:history     im:history
im:read             im:write           mpim:history       reactions:read
reactions:write     users:read         assistant:write
```

**Note the discrepancy:** the tutorial says *"do not add `assistant:write` —
this triggers a Slack-managed AI UI that conflicts with OpenClaw's handling."*
The live app **has it anyway** and works. Either the conflict was never hit or
it was granted before the guidance was written. **Do not grant it on the new
app** — start without it; add only if something demonstrably needs it.

---

## 1. Slack side — create the app

At <https://api.slack.com/apps> → **Create New App** → **From an app manifest**
→ pick the Trillion Parameter Consortium workspace.

Paste the manifest below. It is `luoji`'s; for cecat change `name`,
`display_name`, and `request_url`-free fields accordingly.

```yaml
display_information:
  name: LuoJi
  description: LuoJi agent (OpenClaw)
  background_color: "#2c2d30"
features:
  bot_user:
    display_name: LuoJi
    always_online: true
oauth_config:
  scopes:
    bot:
      - app_mentions:read
      - channels:history
      - channels:read
      - chat:write
      - files:read
      - files:write
      - groups:history
      - groups:read
      - im:history
      - im:read
      - im:write
      - mpim:history
      - reactions:read
      - reactions:write
      - users:read
settings:
  event_subscriptions:
    bot_events:
      - app_mention
      - message.channels
      - message.groups
      - message.im
      - message.mpim
  interactivity:
    is_enabled: false
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

Then, in order:

1. **Basic Information → App-Level Tokens → Generate Token and Scopes.**
   Name it `socket`, add scope `connections:write`. This yields the
   **`xapp-…`** token. Socket Mode will not connect without it.
2. **Install App → Install to Workspace.** Approve. This yields the
   **`xoxb-…`** bot token.
3. **Invite the bot to its channels** — `/invite @LuoJi` in each channel that
   agent should serve. Membership is the access control; an uninvited bot
   receives nothing.

### Things that cost time on luoji's app (2026-08-31 / 09-01)

Executed for luoji. The first three came from building the app in the UI instead of
pasting the manifest above — paste the manifest and those three do not arise. The
last two arise regardless; read them before declaring an app healthy.

1. **Scopes must go on the BOT token, not the User token.** The UI presents
   *Bot Token Scopes* and *User Token Scopes* adjacently. Scopes granted to the
   user token authenticate as the human operator, so posts appear to come from
   *you*, not the agent — which defeats the point of a per-agent app. OpenClaw's
   Socket Mode connection uses the bot token.

2. **`groups:read` is required for a PRIVATE channel.** `channels:read` covers
   public channels only. Agent channels here are private (`#agent-<name>`), so
   omitting it makes `conversations.info` fail. Diagnose precisely — Slack names
   the missing scope in the JSON body:

   ```
   curl -sS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
     "https://slack.com/api/conversations.info?channel=$SLACK_CHANNEL_ID"
   # {"ok":false,"error":"missing_scope","needed":"groups:read","provided":"…"}
   ```

   Note the error progression: `channel_not_found` **before** the bot is invited
   (Slack hides channels it cannot see, so this does NOT mean a bad ID), then
   `missing_scope` after. Reaching `missing_scope` is evidence the invite worked.

3. **Three different names, only one of which the workspace shows.**

   | Field | Where | Effect |
   |---|---|---|
   | App name | Basic Information → Display Information | Admin UI only |
   | **Bot display name** | **App Home → Your App's Presence** | **What the workspace shows** |
   | Handle | derived at install | `@`-mention text; not editable |

   Renaming the app does **not** rename the bot. Set the display name to the
   exact string in the agent's `IDENTITY.md` (`LuoJi`, capital J) — matching that
   string is the entire purpose of this phase.

**Token stability on reinstall (measured, contradicts common assumption):**
adding scopes to an existing install **does not** rotate the `xoxb` bot token —
it is updated in place. The `xapp` app-level token is also unaffected. The
`xoxp` user token *does* change. Re-verify rather than assuming either way.

### The manifest does NOT enable events — check the toggle (2026-09-01)

**This is the one that cost the most time, and pasting the manifest does not
prevent it.** The manifest above declares `settings.event_subscriptions.bot_events`,
and Slack accepted it — but on the created app, **Event Subscriptions → Enable
Events was OFF**. Scopes grant permission to *receive* events; the toggle decides
whether Slack *sends* any. With it off, everything looks healthy:

- `auth.test` → ok, `apps.connections.open` → ok
- the gateway logs `slack socket mode connected` and `channels resolved: …`
- and not one event ever arrives

After enabling it, the same mention immediately logged
`Inbound app_mention … -> bot:U…`. No reinstall was required, and no restart —
it took effect on the live connection.

**Verify events, not connection.** "socket mode connected" proves the outbound
WebSocket opened; it says nothing about whether Slack will push to it. Post a
mention and confirm an `Inbound app_mention` line appears.

### Testing: a message sent with an API token will be IGNORED

Do not conclude the agent is broken from a scripted `chat.postMessage` test.
Slack stamps any message sent with an app-owned token (**including a user token**)
with a `bot_id`, and OpenClaw ignores bot-authored messages to prevent reply
loops. The event is received and silently dropped — no error, no reply:

```
18:17:17 Inbound app_mention … (channel, 50 chars)     <- scripted: received, dropped
18:37:38 Inbound app_mention … (channel, 34 chars)     <- typed by a human
18:37:41 delivered reply to channel:<channel-id>              <- only this one replies
```

Check with `conversations.history`: a human message has `bot_id: None`. **The
pass condition can only be exercised by a human typing in Slack.**

### Enterprise approval — the likely delay

This is a Consortium workspace. The tutorial flags this exact risk: *"each Slack
app needs separate workspace approval, which is slow in an enterprise."* If
**Install to Workspace** shows *"request approval"* rather than installing, you
are blocked on a workspace admin, not on anything technical. That is the whole
reason D2 was published in Aug 2026 and never executed.

If approval will take days, the single-account workaround in §I.1 stays valid —
but record it as a deliberate choice, not a default.

---

## 2. OpenClaw side — config shape

**Target the STAGING planes (2026.7.1), not the old 6.11 gateway.** The old one
is being retired in Phase H; do not add accounts to it.

Migration is non-destructive: adding a non-default account promotes the existing
top-level single-account settings into `accounts.default`, so the original bot
keeps working.

```json5
{
  channels: {
    slack: {
      accounts: {
        default: { name: "chattpc", botToken: "xoxb-…", appToken: "xapp-…" },
        luoji:   { name: "LuoJi",   botToken: "xoxb-…", appToken: "xapp-…" },
      },
    },
  },
  bindings: [
    { agentId: "luoji", match: { channel: "slack", accountId: "luoji" } },
  ],
}
```

Both lists still matter: with `groupPolicy: "allowlist"`, a channel must appear
in **`channels.slack.channels`** *and* have a binding, or events are silently
dropped.

After editing, run `openclaw doctor --fix` — it repairs mixed
single/multi-account shapes.

---

## 3. Constraints that will bite

- **`docker exec -u sandbox`, always.** A root-owned file under
  `/sandbox/.openclaw/` breaks the gateway. `docker cp` preserves the host uid —
  `chown sandbox:sandbox` after.
- **Do not touch Gandalf's :8080 plane.** Frozen v0.0.55 / OpenShell 0.0.44.
- **Egress:** Socket Mode holds an outbound WebSocket to Slack from *inside* the
  sandbox. There is no `slack` entry in `bringup/50-openshell-policies/` — the
  built-in `slack` preset comes from NemoClaw's blueprint. Confirm it is applied
  to each plane before expecting a connection; a blocked WebSocket looks like an
  app that installed fine and simply never comes online.
- **`openclaw doctor`'s gateway probe is a guaranteed false negative** via
  `docker exec` — different network namespace. Not a fault.
- **This repo is public.** No Slack channel/user IDs (`C…`, `U…`, `D…`), no
  workspace-internal names in prose. Tokens go in config only, never in git.

---

## 4. Verify — do not stop at "it installed"

1. Bot shows **online** in the member list.
2. `@LuoJi` in its channel → LuoJi answers, and does **not** say "I am not
   chattpc". That denial is the entire bug being fixed; its absence is the pass
   condition.
3. `@chattpc` still routes as before — confirms non-destructive migration.
4. Gateway log shows the message arriving with the expected `accountId`.
5. Repeat end-to-end for cecat before declaring Phase E done.

---

## 5. Open question this closes

Tutorial decision **D2**. §I.1's status note says the multi-account config *"has
not been exercised on our deployment… we have not registered a second Slack app
and watched a message route to a second agent."* Once step 4.2 passes, that
paragraph should be rewritten from documented-behavior to observed-behavior, and
the result recorded in `runlog/`.
