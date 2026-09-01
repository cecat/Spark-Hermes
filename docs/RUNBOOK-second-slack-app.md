# Runbook — register a per-agent Slack app

Verified against the live deployment 2026-09-01. Staging planes run OpenClaw
**2026.7.1**; the old live gateway runs **2026.6.11**. The `accounts` /
`bindings[].match.accountId` schema is present in 2026.7.1 and is what luoji's
running config uses.

Goal: give cecat and luoji each their own Slack bot identity, so an agent is
never @-mentioned by a handle its `IDENTITY.md` says is not its name.

---

## 0. What exists today (do not re-derive)

Current single app, one shared bot user, serving both agents; routing is by
channel:

| Agent | Bound channels |
|---|---|
| cecat | 1 channel |
| luoji | 3 channels |

Live bot scopes, read from the token — 15 of them:

```
app_mentions:read   channels:history   channels:read      chat:write
files:read          files:write        groups:history     im:history
im:read             im:write           mpim:history       reactions:read
reactions:write     users:read         assistant:write
```

**`assistant:write` is the one exception to "copy the live app."** It triggers a
Slack-managed AI UI that conflicts with OpenClaw's own handling. **Do not grant
it on a new app** — the manifest in §1 omits it deliberately. Add it only if
something demonstrably needs it.

---

## 1. Slack side — create the app

**Creation takes two stages.** Slack rejects a creation manifest that sets
`socket_mode_enabled: true`:

> *Your manifest has Socket Mode enabled, which requires additional setup in
> App Settings. You can still create your app first, then complete the setup
> there.*

Socket Mode needs an app-level token, which cannot exist before the app does.
So create the app **without** socket mode, mint the token, then turn it on.
`event_subscriptions` is deferred with it, since event delivery rides the
socket connection.

At <https://api.slack.com/apps> → **Create New App** → **From an app manifest**
→ pick the workspace the other agents are installed in.

Paste the **creation** manifest below.

> ⚠️ **Change all three `<AGENT>` placeholders before pasting.** Slack does not
> warn about duplicate app names, so an unedited manifest silently creates a
> second app with an existing agent's name, sitting next to the live one in the
> app picker.
>
> If that happens, rename rather than delete: Basic Information → App name,
> **and** App Home → Your App's Presence → Bot display name. To tell two
> same-named apps apart, resolve the working token to its `app_id`:
>
> ```bash
> set -a; . ~/.openclaw-secrets/<agent>-slack.env; set +a
> BOT=$(curl -sS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
>   https://slack.com/api/auth.test | jq -r .bot_id)
> curl -sS -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
>   "https://slack.com/api/bots.info?bot=$BOT" | jq -r '.bot.app_id'
> ```

```yaml
display_information:
  name: <AGENT>                          # e.g. CeCat — must be unique in the workspace
  description: <AGENT> agent (OpenClaw)
  background_color: "#2c2d30"
features:
  bot_user:
    display_name: <AGENT>                # what the workspace actually shows
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
  interactivity:
    is_enabled: false
  org_deploy_enabled: false
  token_rotation_enabled: false
```

**What the wizard shows** (so you know you are on track): after pasting, **Next**
becomes selectable. Slack then shows a **"Create and Install"** review page
summarising the app name, the bot user, and the requested scopes. Its button
leads to the standard OAuth consent screen, listing what the app will be able to
do; the green button there is **Allow**. Take both.

You land on **Basic Information**, and the app is installed to the workspace —
so the `xoxb-` bot token already exists, retrievable from **OAuth & Permissions**
(step 4 below is then a no-op unless you later change scopes).

Then, in order — note the app-level token now comes *before* socket mode, which
is forced by the dependency above, not a style choice:

1. **Mint the app-level token.** Left-hand sidebar → **Basic Information**,
   scroll down to **App-Level Tokens** → *Generate Token and Scopes*.
   Name it **`<agent>-socket`** (luoji's is `luoji-socket`) — token names are
   per-app but you will be reading them across several apps, so a bare `socket`
   is ambiguous. Add scope `connections:write`. This yields the **`xapp-…`**
   token; copy it now, Slack shows it once. Socket Mode will not connect without
   it.
2. **Enable Socket Mode.** In the left-hand navigation sidebar, under the
   **Settings** group, click **Socket Mode** — this is a separate page, not a
   section of Basic Information. Toggle **Enable Socket Mode** on. Slack may
   enable interactivity alongside it; harmless.
3. **Enable events, and subscribe to them — two separate things.** Left-hand
   sidebar, **Features → Event Subscriptions** (a different group from Socket
   Mode). Toggle **Enable Events** on. Then expand *Subscribe to bot events* and
   **add all five, one at a time** — the list starts EMPTY, because the creation
   manifest in this runbook deliberately omits `event_subscriptions`:

   ```
   app_mention        message.groups     message.mpim
   message.channels   message.im
   ```

   Click **Save Changes** at the bottom; the page does not autosave.

   **Both halves are required and each fails silently on its own.** Events
   enabled with an empty subscription list delivers exactly nothing, and looks
   identical to a healthy app — `auth.test` ok, `socket mode connected`,
   channels resolved, and not one event. This is the most expensive failure in
   this runbook; see *"The manifest does NOT enable events"* below.

   *Faster alternative to steps 2–3:* now that the app-level token exists, paste
   the **full** manifest — the one carrying `socket_mode_enabled: true` and the
   `event_subscriptions.bot_events` block — into **Settings → App Manifest →
   Save Changes**. That sets socket mode and all five subscriptions at once.
   Afterwards still open Event Subscriptions and confirm the toggle is on and
   the five events are present: the manifest declares subscriptions but does not
   flip the toggle.
4. **Copy the bot token.** Left-hand sidebar, **Features → OAuth & Permissions**
   (same group as Event Subscriptions). The **`xoxb-…`** value is at the top of
   that page as *Bot User OAuth Token* — the wizard already installed the app,
   so it exists. Only if you changed scopes after creation do you need
   **Settings → Install App → Reinstall to Workspace** first; a token does not
   pick up new scopes otherwise.
5. **Invite the bot to its channels.** This step happens **in Slack itself**,
   not in the app-configuration site — switch to the Slack client, open each
   channel the agent should serve, and type `/invite @<Agent>`. Membership is
   the access control; an uninvited bot receives nothing.

**The Slack app is now configured, but the agent is not.** Nothing will respond
yet: the sandbox still needs its egress preset, the Slack plugin, and its config
block. Continue at §1a and §2 — §4 is the verification for the whole thing.

Before moving on, confirm on the Event Subscriptions page that the toggle is on
**and** five events are listed. That single check catches the failure that looks
most like success.

### Reference — what goes wrong

*Not a checklist; consult when something misbehaves.* The three numbered items
only arise if you build the app in the UI instead of pasting the manifest. The
two subsections after them can arise either way.

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
   exact string in the agent's `IDENTITY.md` (`LuoJi`, capital J; `CeCat`) —
   matching that string is the entire purpose of this phase.

**Token stability on reinstall (measured, contradicts common assumption):**
adding scopes to an existing install **does not** rotate the `xoxb` bot token —
it is updated in place. The `xapp` app-level token is also unaffected. The
`xoxp` user token *does* change. Re-verify rather than assuming either way.

### The manifest does NOT enable events — check the toggle

**The most expensive failure in this runbook, and pasting the manifest does not
prevent it.** A manifest declaring `settings.event_subscriptions.bot_events` is
accepted, yet the created app has **Event Subscriptions → Enable Events OFF**.
Scopes grant permission to *receive* events; the toggle decides whether Slack
*sends* any. With it off, everything looks healthy:

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

### Enterprise approval — a possible delay

Each Slack app needs its own workspace approval. If the install shows *"request
approval"* rather than completing, you are blocked on a workspace admin, not on
anything technical. This has not been hit on this workspace so far.

---

## 1a. Store the tokens on the host

Before touching any config, park the tokens in the established location — a
host-side, mode-600 env file per agent:

```
~/.openclaw-secrets/<agent>-slack.env     # dir is mode 700
```

```
SLACK_BOT_TOKEN=xoxb-…
SLACK_APP_TOKEN=xapp-…
SLACK_CHANNEL_ID=C…
```

**Two tokens, and only two.** A Slack app can also issue a *user* token
(`xoxp-…`), and luoji's env file carries one — it is unused. The gateway never
reads it: `userToken` appears nowhere in `openclaw.json`, and an `auth.test`
with it authenticates as the human operator, not the agent. It was minted while
trying to verify inbound messages with a script, which does not work (see the
testing note in §1). **Do not create one.** The manifest in §1 grants no user
scopes, so the option will not arise unless you go looking for it.

```bash
touch ~/.openclaw-secrets/<agent>-slack.env
chmod 600 ~/.openclaw-secrets/<agent>-slack.env
```

Two things to understand about this file, because neither is obvious:

- **Nothing reads it automatically.** No script or systemd unit sources it; it
  is an operator-side record so the tokens survive outside a sandbox writable
  layer and are re-appliable after a rebuild. The values are transcribed by hand
  into `openclaw.json` in §2. If you skip this file the agent still works — until
  the day you need the tokens back and Slack will only show you `xapp-` once.
- **It is not the sandbox `.env`.** It never enters the container. The gateway
  reads tokens from `/sandbox/.openclaw/openclaw.json`, not from an environment
  variable.

`SLACK_CHANNEL_ID` is stored here too — it is the one place a real channel ID
may be written down, since this path is outside the repo. Keep IDs out of
anything committed.

---

## 2. OpenClaw side — config shape

**Target the STAGING planes (2026.7.1), not the old 6.11 gateway.** The old one
is being retired in Phase H; do not add accounts to it.

Three steps, in this order. All three were needed for both luoji and cecat —
none is optional, and the first two are invisible in the config file.

### 2a. Never drive a plane with the global `nemoclaw`

Every command below goes through **`ops/nmc.sh <agent> …`**. Read its header
before working around it.

`nemoclaw` on PATH is **v0.0.55** — Gandalf's, frozen, and hardcoded to a single
control plane. Aimed at an agent on :8090/:8091 it does not fail; it relaunches a
gateway on that port with its own defaults (plaintext where the sandbox requires
mTLS, `OPENSHELL_DB_URL` pointing at Gandalf's database) and rewrites Gandalf's
gateway entry in place. `nemoclaw luoji policy-list` did this on 2026-09-01 and
caused a 93-restart loop. The verb was read-only-sounding; the damage came from
the binary, so there is no safe subcommand.

Check the argv0 tag if you suspect a hijacked plane — a correct gateway is
tagged, an impostor is a bare path:

```bash
pgrep -af "openshell-gateway\["   # want: openshell-gateway[nemoclaw=nemoclaw-8091;port=8091]
```

### 2b. Egress preset — per agent, not inherited

```bash
cp bringup/50-openshell-policies/luoji-slack-egress.yaml \
   bringup/50-openshell-policies/<agent>-slack-egress.yaml
# edit: preset name, policy key, comments. Endpoints and binary stay as-is.

bash ops/nmc.sh <agent> policy add \
  --from-file bringup/50-openshell-policies/<agent>-slack-egress.yaml --dry-run
bash ops/nmc.sh <agent> policy add \
  --from-file bringup/50-openshell-policies/<agent>-slack-egress.yaml --yes
bash ops/nmc.sh <agent> policy list | grep "●"      # expect ● <agent>-slack-egress
```

Both OpenClaw agents use the identical file bar the names — same endpoints, same
`node` binary. There is also a built-in `slack` preset (`○ slack`); neither agent
uses it. Mirror the agent that works.

### 2c. Install the Slack plugin — via `nemoclaw exec`, not `docker exec`

```bash
bash ops/nmc.sh <agent> exec -- openclaw plugins install @openclaw/slack
PATH="$HOME/gandalf-bringup/openshell-0.0.101/bin:$PATH" \
  openshell gateway select nemoclaw      # see the warning below
```

Slack left OpenClaw core in 2026.7.1; without the plugin the gateway logs
`no-channel-owner` and never opens a socket.

- **`docker exec … openclaw plugins install` cannot work.** The L7 proxy
  authorises by peer binary and cannot resolve a docker-exec caller:
  `DENIED → registry.npmjs.org:443 [reason:failed to resolve peer binary]`.
  That reads like a missing npm policy and is not — `npm` is already enabled.
  `nemoclaw exec` runs through the gateway, where resolution works.
- If you must use `docker exec` for something else, set **`HOME=/sandbox`**.
  Unset, openclaw looks in `/root` and dies with `EACCES`.
- ⚠️ **`nemoclaw exec` flips the GLOBAL default gateway** to that agent's plane.
  Gandalf's tooling then reports nonsense until you run the `gateway select`
  line above. Nothing is actually broken.

### 2d. Config and binding

The file is `/sandbox/.openclaw/openclaw.json` (mode 600, `sandbox`-owned).
`ops/apply-cecat-slack.sh` writes this block from
`~/.openclaw-secrets/cecat-slack.env` and is worth copying for a new agent.
Below is **luoji's live block, read back from the running sandbox** — not an
idealized example:

```json5
{
  channels: {
    slack: {
      enabled: true,
      mode: "socket",
      groupPolicy: "allowlist",
      dmPolicy: "open",
      dm: { enabled: true },
      accounts: {
        luoji: { name: "LuoJi", botToken: "xoxb-…", appToken: "xapp-…" },
      },
      channels: {
        "C…": { requireMention: true, enabled: true },   // real ID here; never in git
      },
      allowFrom: ["*"],
    },
  },
  bindings: [
    { agentId: "main", match: { channel: "slack", accountId: "luoji" } },
  ],
}
```

Two things to get right:

- **`agentId` is `"main"`, not the agent's name.** Each staging plane runs one
  sandbox with one agent, and OpenClaw calls it `main`. `agentId: "luoji"`
  matches nothing and the binding silently never fires.
- **There is no `accounts.default`.** That shape belongs to the old shared
  gateway, which served both agents from one app. Each staging plane is a
  separate sandbox with its own config file and exactly one account, named for
  the agent — nothing on cecat's plane can disturb luoji's.

Both lists still matter: with `groupPolicy: "allowlist"`, a channel must appear
in **`channels.slack.channels`** *and* have a binding, or events are silently
dropped.

Edit it in place inside the sandbox (`docker exec -u sandbox`, per §3), then
restart the gateway.

After editing, run `openclaw doctor --fix` — it repairs mixed
single/multi-account shapes.

---

## 3. Constraints that will bite

- **`docker exec -u sandbox`, always.** A root-owned file under
  `/sandbox/.openclaw/` breaks the gateway. `docker cp` preserves the host uid —
  `chown sandbox:sandbox` after.
- **Do not touch Gandalf's :8080 plane.** Frozen v0.0.55 / OpenShell 0.0.44.
- **Egress: each agent needs its OWN Slack preset — not optional, not
  inherited.** Socket Mode opens an outbound WebSocket from *inside* the
  sandbox, and the L7 proxy authorises by **peer binary**: Hermes reaches Slack
  as Python, OpenClaw as `/usr/local/bin/node`.
  Presets are therefore per-sandbox and **not portable between agents**. Copy
  `bringup/50-openshell-policies/luoji-slack-egress.yaml`, rename the preset and
  policy key, and apply it to the new agent's plane. Two hosts are required —
  `slack.com` (Web API) *and* `wss-primary.slack.com` (the WSS upgrade);
  omitting the second yields an endless "failed to retrieve a new WSS URL"
  retry loop even though `slack.com` is allowed. Symptom of a missing preset:
  `DENIED /usr/local/bin/node -> slack.com:443`.
- **Do not apply policies with `ops/apply-policies.sh`.** It pushes *every* YAML
  in the directory to **gandalf**, which would load another agent's preset onto
  the wrong sandbox. Until it learns about per-agent planes, apply by hand:
  `source ops/<agent>-env.sh` then
  `openshell sandbox policy add <agent> --from-file <file> --yes`.
- **`openclaw doctor`'s gateway probe is a guaranteed false negative** via
  `docker exec` — different network namespace. Not a fault.
- **This repo is public.** No Slack channel/user IDs (`C…`, `U…`, `D…`), no
  workspace-internal names in prose. Tokens go in config only, never in git.

---

## 4. Verify — do not stop at "it installed"

1. Bot shows **online** in the member list.
2. **A human types `@<Agent>` in its channel** — not a script; see the testing
   note in §1. The agent answers, and does **not** deny being itself. On luoji
   the old failure was "I am not chattpc"; its absence is the pass condition.
3. Gateway log shows `Inbound app_mention` *and* a `delivered reply to
   channel:…`. "socket mode connected" alone is not a pass. The log lives inside
   the sandbox — there is no host-side copy:

   ```bash
   CON=$(docker ps --format '{{.Names}}' | grep openshell-default--<agent>)
   docker exec -u sandbox "$CON" sh -c \
     'tail -50 /sandbox/.openclaw/logs/gateway-persistent.log'
   ```
4. The old shared `@chattpc` app still routes as before — it serves production
   until Phase 6, so confirm the new plane did not disturb it.
5. Repeat end-to-end for the second agent before declaring Phase E done.

---

## 5. Status

Per-agent Slack apps are no longer theoretical here: luoji's was registered
2026-08-31 and verified end-to-end 2026-09-01 (`@LuoJi` in its test channel →
`Inbound app_mention` → `delivered reply`). Record cecat's result in `runlog/`
when hers passes.
