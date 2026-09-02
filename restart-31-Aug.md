# Restart handoff — 2026-08-31 / 09-01

> **§1 RESOLVED 2026-09-01 ~04:00.** The luoji restart loop is fixed; all three
> planes are healthy. **The root-cause hypothesis in §1 below was wrong in one
> load-bearing way — read "§1-RESOLVED" at the bottom of this file before acting
> on anything in §1.** In particular: do NOT delete the `nemoclaw` gateway entry.
> It is Gandalf's own entry, not a stray.

Written at the end of a session that (a) completed the Slack-app half of Phase E,
(b) found the real reason Slack doesn't work on the new stack, and (c) **left
luoji's staging sandbox in a restart loop.** Item (c) is the first thing to fix.

**`Spark-Hermes` is a PUBLIC repo.** No credentials or Slack IDs appear below.
This file is untracked scratch — delete it once its contents have landed in
`docs/FOLLOWUPS.md` and `runlog/`.

---

## 1. BROKEN RIGHT NOW — luoji staging sandbox restart-looping

**Container:** `openshell-default--luoji-<uuid>` (`docker ps -a | grep luoji`)

**Symptom:** `RestartCount: 39` and climbing, `RestartPolicy: unless-stopped`,
health flaps `starting`→`healthy`, but the agent gateway process never launches.
`docker logs` shows:

```
openshell_sandbox: Fetching sandbox policy via gRPC
WARN openshell_sandbox: Policy fetch failed, retrying     <-- loops forever
openshell: log push connect failed: failed to connect to OpenShell server
```

**Root cause:** the sandbox cannot reach its **OpenShell control plane on
:8091**, so it never gets its policy and never starts `nemoclaw-start` (the
supervisor that launches `openclaw-gateway`). The container entrypoint is
`/opt/openshell/bin/openshell-sandbox`, which does **not** start the gateway on
its own — `docker start` alone can never fix this.

**What I did to cause it.** I ran `nemoclaw luoji policy-list` believing it was a
read-only query. It is not. It:

1. printed `Active gateway set to 'nemoclaw'` — **mutated the selected control
   plane**, ignoring `OPENSHELL_GATEWAY=nemoclaw-8091`;
2. decided the Docker-driver gateway was "stale
   (`OPENSHELL_DISABLE_TLS=<unset>` expected `true`)" and **restarted it**;
3. answered `Sandbox 'luoji' does not exist. Registered sandboxes: gandalf`
   — it was talking to the *wrong plane* the whole time;
4. and luoji's sandbox exited 143 (SIGTERM) as collateral.

**Do not re-run `nemoclaw <agent> policy-list` on 8090/8091.** Treat every
`nemoclaw` subcommand as state-mutating until proven otherwise. `nemoclaw` here
is the v0.0.108 sidecar; the agent planes are driven through `openshell` with
`ops/<agent>-env.sh` sourced.

### Collateral to check before anything else

- **`openshell gateway list` now shows a stray `nemoclaw` entry** →
  `http://127.0.0.1:8091`, **plaintext, `SOURCE=user`**, next to the correct
  `nemoclaw-8091` → `https://127.0.0.1:8091` (mTLS). The stray one is almost
  certainly wrong and was created by step 1 above. Probably wants removing, but
  confirm before deleting — I have already been wrong once tonight about what is
  safe to run.
- **cecat's plane (:8090):** `curl -k https://127.0.0.1:8090` returns
  `tlsv13 alert certificate required`. That is **expected for mTLS without a
  client cert** and is probably fine — cecat's sandbox is `Up 10 days (healthy)`.
  Verify properly via `openshell` with `ops/cecat-env.sh` sourced. Do not assume
  breakage from the curl alone.

### Suggested recovery (NOT verified — think before running)

The goal is to get the :8091 control plane healthy and re-attached, then let the
sandbox fetch policy and start its supervisor.

```bash
source ~/code/Spark-Hermes/ops/luoji-env.sh   # sets OPENSHELL_GATEWAY=nemoclaw-8091
openshell gateway list                        # is nemoclaw-8091 up and selected?
openshell sandbox list                        # does it see 'luoji'?
```

Then find whatever restarts the :8091 daemon. `ops/agent-planes.sh` (untracked,
~9 KB, has a `start` verb — the workspace script's error text references
`bash ops/agent-planes.sh start`) is the most likely correct tool. **Read it
first.**

**Consider stopping the flapping container** (`docker stop`) while diagnosing, so
it is not restarting every ~20 s. It is safe to stop; see the data note below.

### Data is NOT at risk

Writable layer intact: 55 workspace files, all of `/sandbox/.openclaw/`. The
sandbox was **stopped, never removed**. Never `rebuild`/recreate an OpenShell
sandbox — there are no bind mounts and the writable layer is the only copy.

Config backups of luoji's `openclaw.json`:
- host: `~/.openclaw-config-backups/luoji/openclaw.json.20260901T032511Z`
- in-sandbox: `/sandbox/.openclaw/openclaw.json.pre-slack-20260901T032511Z`

---

## 2. THE REAL PHASE E BLOCKER (this is the useful finding)

**In OpenClaw 2026.7.1, Slack is no longer built into core. It is an external
plugin, `@openclaw/slack`.** Nothing is missing from the NemoClaw image and
nothing was stripped — the delta is upstream, 6.11 → 7.1.

Evidence, from the catalog inside the sandbox
(`dist/official-external-plugin-catalog-*.js`):

```json
{ "name": "@openclaw/slack", "description": "OpenClaw Slack channel plugin",
  "source": "official", "kind": "channel",
  "openclaw": { "channel": { "id": "slack", "selectionLabel": "Slack (Socket Mode)" },
    "install": { "npmSpec": "@openclaw/slack", "defaultChoice": "npm",
                 "minHostVersion": ">=2026.5.12-beta.1" } } }
```

That is exactly why the gateway logs, with a valid config:

```
configured channel warning: channels.slack is configured but no channel plugin
is installed or loadable (no-channel-owner).
```

**Install path:** `openclaw plugins install @openclaw/slack` (the CLI has an
`install` verb accepting npm spec / path / archive / `clawhub:`).

**The obstacle:** the sandbox has **no npm egress**.

```
curl https://registry.npmjs.org/... -> Could not resolve host (15.8 s)
```

So Phase E now needs **one of**:
- an npm egress allowlist for the agent planes — see
  `Spark-Hermes/bringup/50-openshell-policies/` for the pattern (`tavily-egress.yaml`,
  `google-workspace-egress.yaml`); or
- an offline install — fetch the tarball on the host, `docker cp` it in, install
  from the archive path (remember `-u sandbox` and `chown` after `docker cp`).

Only `telegram` ships as a bundled channel plugin in this image. Extension count
is 70 (new) vs 76 (old 6.11) and the only real differences are `codex`,
`diagnostics-otel`, and test scaffolding — **not** Slack.

### Two dead ends — do not repeat

1. **"NemoClaw stripped Slack from the image."** Wrong. Neither image has a
   `slack` extension dir, because in 6.11 Slack was core. I concluded this from a
   missing directory without checking the counter-case; Charlie's pushback
   ("Hermes can talk to Slack but OpenClaw cannot?") is what forced the recheck.
   Hermes uses Python `slack_sdk`/`slack_bolt` in its venv — a different
   mechanism entirely, and not evidence about OpenClaw either way.
2. **`openclaw gateway restart`** cannot work in these sandboxes — it drives
   systemd/launchd and there is none. Correct restart is
   `kill -TERM <gateway-pid>`; NemoClaw's supervisor respawns it in ~5 s.
   *(This only works while `nemoclaw-start` is running — which it currently is
   not. See §1.)*

---

## 3. DONE AND VERIFIED — Slack app for luoji

Registered against the real Slack workspace, all checks via API, not the UI.

| Item | State |
|---|---|
| App / bot display name | `LuoJi` (matches `IDENTITY.md` exactly, capital J) |
| Bot handle | `@luojiagent` — fixed at install, not editable |
| Bot token scopes | 15, incl. `groups:read` (needed for private channels) |
| App-level token | valid; `apps.connections.open` issues a WebSocket |
| Test channel | private, **bot is a member**, unknown to the old gateway |
| Credentials | `~/.openclaw-secrets/luoji-slack.env`, mode 600, outside all repos |

Channel ID is in that env file — deliberately not written here.

**Config already written into luoji's staging `openclaw.json`** (survived the
crash, verified): `channels.slack.accounts.luoji` with both tokens,
`bindings[] → {agentId: "main", match: {channel: "slack", accountId: "luoji"}}`,
allowlist containing only the test channel, `allowFrom: ["*"]`.

**Tutorial decision D2 is partly settled already.** `openclaw doctor` reported
*"Moved channels.slack single-account top-level values into
channels.slack.accounts.default"* — the runtime understands multi-account Slack
and the migration is non-destructive, as §I.1 predicted. What remains unproven is
end-to-end routing, which needs the plugin.

**Pass condition when you get there:** `@LuoJi` in the test channel returns a
reply that does **not** deny its own name. That denial is the entire bug §I.1
describes.

**One-line fix still worth making:** add to luoji's `IDENTITY.md` that it is also
addressed as `@luojiagent` in Slack and that this does not contradict its name.
The handle can't be renamed, so this closes the residual mismatch for free.

Full procedure + three UI gotchas (bot-vs-user scopes, `groups:read` for private
channels, three different name fields) are written up in
`Spark-Hermes/docs/RUNBOOK-second-slack-app.md`. Paste the manifest for cecat's
app and none of them recur.

---

## 4. Other findings from this session

- **The 30-minute Opus calls on both staging sandboxes are the OpenClaw
  gateway's own heartbeat** — `[heartbeat] started` at gateway boot. Not host
  cron, not native `cron.list` (empty), not NemoClaw. Both staging agents have
  been running a heartbeat loop against a half-wired environment since Aug 21,
  invisible to `collect-token-usage.sh` (which only scrapes the old
  `openclaw-gateway`). Charlie: *"none of the agents are doing important work
  now"* — so this is spend, not damage. **Decide whether to disable it before
  cutover.**
- **Ten days of drift** (Aug 21 → 31): no commits in either repo; the cutover sat
  exactly where `HANDOFF-2026-08-21d` left it.
- **Phase D triage (not started, unblocked).** Only ~3 of the 7 scripts need
  porting: `collect-token-usage.sh`, `monitor-gateway-models.sh`,
  `ops/reset-agent.sh`. `seed-sessions.sh` is likely obsolete — native cron
  exists in 7.1. `test-infra.sh` (623 lines) asserts old-stack shape; rewrite,
  don't port. All seven hardcode `docker exec openclaw-gateway`; the agent→
  container map belongs in `shared/config.sh`, which has no such map today.
- **iptables persistence still unproven.** `ops/fix-sandbox-iptables.sh` ran
  2026-08-21; host last booted 2026-08-15. No reboot since, so the FOLLOWUPS
  action item "re-run `--check` after the next reboot" is still outstanding.
- **`spark-ai-agents` working tree is dirty** — ~17 untracked files (cecat triage
  scripts, `luoji/media/`, `luoji/sibline/`, three Aug-11 `.tgz`). Unrelated, but
  it will complicate the Phase H merge of `cecat-openshell-migration`.
- **`.gitignore` updated** in `spark-ai-agents` (`.openclaw-secrets/`, `*.env`) —
  the only tracked change made this session. `Spark-Hermes` has an updated
  `docs/RUNBOOK-second-slack-app.md` and an untracked `ops/phase0-runner.py`
  that predates this session.

---

## 5. Standing constraints (unchanged, still binding)

- **Never touch Gandalf's :8080 plane** — frozen v0.0.55 / OpenShell 0.0.44.
  Verified healthy throughout: Hermes running, container up 13 days.
- **Never recreate/rebuild a sandbox** — no bind mounts; writable layer is the
  only copy. Stopped is recoverable; removed is not.
- **`docker exec -u sandbox`, always.** Root-owned files under
  `/sandbox/.openclaw/` break the gateway. `docker cp` preserves host uid —
  `chown sandbox:sandbox` after.
- **`openclaw doctor`'s gateway probe is a guaranteed false negative** via
  `docker exec` (different netns). To reach the gateway:
  `docker exec -u root <con> nsenter -t <gateway-pid> -n runuser -u sandbox -- env HOME=/sandbox openclaw <cmd>`
- **`phase: Unspecified`** = wrong `openshell` on PATH; source `ops/<agent>-env.sh`.
- **Both repos are real remotes; `Spark-Hermes` is PUBLIC.** No Slack IDs
  (`C…`/`U…`/`D…`), no tokens, no workspace names in committed prose.
- **The outbox is a safety control, not scaffolding.** Any design where agents
  send Slack/email directly is a regression.

## 6. Working-style notes earned this session

- **Charlie's pushback is usually right.** Twice tonight: "isn't this a private
  channel?" (it was) and "Hermes can talk to Slack but OpenClaw cannot?" (which
  overturned a wrong conclusion). When he questions a claim, recheck it rather
  than defend it.
- **Verify before asserting state.** I twice reported confident conclusions from
  inference rather than measurement — "the new planes are doing nothing" (they
  were running a heartbeat loop) and "Slack isn't in the image" (it is, as an
  external plugin). Both cost time.
- **He cannot copy text out of the Claude Code window** — write commands and
  snippets to files.
- **`~` in an instruction is not self-explanatory.** I said `mkdir -p
  ~/.openclaw-secrets` while he was cd'd into a repo; it landed inside the repo,
  untracked but not ignored. Moved to `~/.openclaw-secrets/`, never committed, no
  exposure, no rotation needed. Say "from your home directory" explicitly.

---

## §1-RESOLVED — what was actually wrong (2026-09-01 ~04:00)

Fixed. `luoji` restart loop stopped at 93 restarts; now `restarts=0`, gateway
`ready`. All three planes healthy. No data lost.

### The correction that matters

§1 said `openshell gateway list` had gained a **stray** `nemoclaw` entry that
"probably wants removing." **It is not stray — it is Gandalf's own entry**, and
deleting it would have broken his tooling outright.

`~/.config/openshell/gateways/nemoclaw/` has `last_sandbox: gandalf`. What
`nemoclaw <agent> policy-list` did was **rewrite its `gateway_endpoint` in place**
from `http://127.0.0.1:8080` to `http://127.0.0.1:8091`. Gandalf's plane entry was
hijacked, not duplicated. That is why `ops/status.sh` reported
`Sandbox phase: Unspecified` while his container was perfectly healthy — the CLI
was querying luoji's port.

### The actual cause of the restart loop

The process listening on :8091 was **not luoji's gateway**. luoji's real gateway
(PID 2776928) was killed; `nemoclaw` replaced it with one started from its own
defaults:

- `OPENSHELL_DISABLE_TLS=true` → **plaintext** on :8091, but luoji's sandbox is
  provisioned for **mTLS** (`https://127.0.0.1:8091`). Hence `Policy fetch failed`
  forever, hence `nemoclaw-start` never ran, hence no `openclaw-gateway`.
- `OPENSHELL_DB_URL` → **Gandalf's** SQLite DB
  (`.../openshell-docker-gateway/openshell.db`, no `-8091` suffix), so two
  gateways were writing one DB.
- no `OPENSHELL_GATEWAY_CONFIG`, no sandbox namespace, and a bare argv0 instead of
  `openshell-gateway[nemoclaw=nemoclaw-8091;port=8091]`.

The argv0 tag is the quickest tell. Compare `pgrep -af openshell-gateway`: a
correct plane gateway carries the `[nemoclaw=...;port=...]` tag (see
`start_gateway()` in `ops/agent-planes.sh` for why NemoClaw needs it).

### One surprise during repair — expect it

Killing the impostor **stopped Gandalf's container** (exit 137). Because it had
adopted Gandalf's DB, it considered his sandbox its own and stopped it on the way
out; PID 1 doesn't trap SIGTERM, so 10 s later SIGKILL. Recovery was
`docker start` on the existing container (never recreate) plus re-establishing
the dead `:8642` port forward, which `ops/start-all.sh` already handles:

```bash
openshell forward stop 8642 gandalf; openshell forward start -d 8642 gandalf
```

### Steps taken

1. Backed up gateway config + state → `~/.openshell-repair-backups/20260901T035500Z/`
   (mode 700; contains mTLS keys).
2. `docker stop` the flapping luoji container; `kill -9` the impostor on :8091
   (it ignored SIGTERM).
3. `PRAGMA integrity_check` on Gandalf's DB → `ok`. `~/.nemoclaw/sandboxes.json`
   still lists only `gandalf` — no cross-agent pollution.
4. Repointed `gateways/nemoclaw/metadata.json` to `http://127.0.0.1:8080`, and
   repaired the clobbered `runtime.json` / `.pid` in Gandalf's state dir (they
   named the dead impostor PID).
5. `docker start` Gandalf; restored the `:8642` forward.
6. `bash ops/agent-planes.sh start` — brought :8091 up correctly and left cecat
   alone. This script was the right tool, as §1 guessed.

### Verified after

- Gandalf: `Ready`, `Inference: OK`, `Slack: bot identity = gandalf`, 5 cron jobs.
  (`Google: token NOT authenticated` is **pre-existing and unrelated** — still open.)
- cecat :8090 `Ready`, inference `claudesonnet46`; never touched.
- luoji :8091 `Ready`, inference `claudeopus47`, `restarts=0`, gateway `ready`.
- Default gateway back to `nemoclaw → http://127.0.0.1:8080`.
- luoji's data intact: 22 workspace entries (`SOUL.md`, `IDENTITY.md`, `memory/`),
  `channels.slack.accounts.luoji` with both tokens, and the binding — all survived.

luoji's gateway now reaches the **§2 blocker** (`no-channel-owner` for
`channels.slack`) instead of crashing. That is the real Phase E work, unchanged.

### Standing rule earned here

§1's "treat every `nemoclaw` subcommand as state-mutating" is right, and stronger
than it looks: `nemoclaw` v0.0.108 invoked **without** a plane's env will not just
mutate the selected plane — it will **relaunch a gateway using its own defaults on
another plane's port, pointed at another plane's database.** Drive the agent planes
through `ops/agent-planes.sh`, or `openshell` with `ops/<agent>-env.sh` sourced.
