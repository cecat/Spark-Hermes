# Telegram bring-up — Phase B blocked at rebuild preflight

**Date:** 2026-06-27
**Operator:** catlett (on `spark-960b`, repo at `00ddfb6` local; `c8abd82` pushed)
**Author:** Claude Code session
**Status:** STOPPED — sandbox untouched, awaiting operator decision before proceeding.

> Continues [`phase-a-findings.md`](phase-a-findings.md). Phase A diagnosed,
> Phase B started, hit an unexpected preflight failure documented here.

---

## TL;DR

`nemohermes gandalf channels add telegram` succeeded through every step EXCEPT
the final rebuild — the rebuild aborted at preflight with `provider credential
not found: COMPATIBLE_ANTHROPIC_API_KEY`. The sandbox is intact, Slack inbound
is still live, and the Telegram bridge is half-provisioned (registry +
egress + preset) but the in-sandbox image hasn't been rebuilt to start the
adapter. The root cause is a recorded `onboard-session.json` field that doesn't
match this deployment's actual inference path, and it would block **any**
future rebuild — not just Telegram.

Four unblock options below, each with different blast radius. Need operator
go-ahead before picking one.

---

## What happened (chronological)

1. **Secrets redaction & banners (commit `00ddfb6`, local only).** Bot token,
   Tavily key, and allowed-user ID replaced with `<BOT_TOKEN>` /
   `<TAVILY_KEY>` / `<ALLOWED_USER_ID>` placeholders in
   `implementation.md` and `phase-a-findings.md`. Superseded banners added
   linking back to `phase-a-findings.md` from `implementation.md` and
   `NEXT-STEPS-FOR-CLAUDE-CODE.md`.

2. **Fresh snapshot.** `nemohermes gandalf snapshot create --name
   pre-telegram-add-v2` — succeeded as **v15** (`2026-06-27T13-03-11-679Z`).
   Same misleading `Snapshot failed. Failed files: runtime/state.db` UX as
   last time; `snapshot list` confirms it landed. Two restore points now:
   - v15 `pre-telegram-add-v2` (current)
   - v14 `pre-telegram` (earlier today, pre-egress)

3. **Source-of-truth review of `channels add` (upstream NemoClaw source at
   `~/gandalf-bringup/nemoclaw-src`).** Key facts that changed the plan:
   - Telegram's allowlist env key is **`TELEGRAM_ALLOWED_IDS`**, NOT the
     `TELEGRAM_ALLOWED_USERS` the README template and your current
     `~/.hermes/.env` use. The bringup README's template is also wrong here.
   - `acquirePasteTokens` only iterates over the bot-token env keys for the
     channel — `TELEGRAM_ALLOWED_IDS` isn't acquired by `channels add`
     itself; it's captured later in the rebuild's `messaging-channel-setup`
     phase, which reads `process.env` directly.
   - `channels add telegram` does these in order: register the bridge with
     OpenShell, auto-apply the built-in `telegram` egress preset, then
     interactively ask `Rebuild now? [Y/n]`.

4. **Env pre-seed.** Sourced `~/.hermes/.env`, then exported:
   - `TELEGRAM_BOT_TOKEN` (already set)
   - `TELEGRAM_ALLOWED_IDS=$TELEGRAM_ALLOWED_USERS` (shimmed because the
     .env uses the older key name)
   - `TELEGRAM_REQUIRE_MENTION=0` (DM-only — answer @mentions-only "no")

5. **Live `channels add telegram`.** Piped `y\n` for the rebuild prompt. The
   command got through gateway-side provisioning cleanly:

   ```
   ✓ Registered telegram bridge with the OpenShell gateway.
   Widening sandbox egress — adding: api.telegram.org
   ✓ Policy version 13 submitted (hash: a6a537c8d6b7)
   ✓ Policy version 13 loaded (active version: 13)
   Applied preset: telegram
   Rebuild 'gandalf' now to apply? [Y/n]:
   ```

   Then on the rebuild:

   ```
   Rebuild preflight failed: provider credential not found.
   The non-interactive recreate step requires COMPATIBLE_ANTHROPIC_API_KEY,
   but it is not set in the environment.

   To fix, do one of:
     export COMPATIBLE_ANTHROPIC_API_KEY=<your-key>
     nemohermes onboard          # re-enter the key interactively

   Sandbox is untouched — no data was lost.
   ```

6. **Stopped.** Did not retry, did not improvise, did not roll back. Captured
   the live state and wrote this file.

---

## Current live state (read-only verified)

| Thing | State |
|---|---|
| Sandbox phase | `Ready` (gateway PID 197 still alive — never restarted) |
| Slack inbound | **Still connected** — NemoClaw env unchanged, no gateway cycle |
| Telegram adapter | **Not running** — image hasn't been rebuilt with new env |
| `messagingChannels` in `~/.nemoclaw/sandboxes.json` | `["slack", "telegram"]` (registry updated) |
| OpenShell policy `telegram` (built-in) | **Active** — auto-applied by `channels add` |
| OpenShell policy `telegram-egress` (custom) | Active (was already loaded earlier today) |
| Policy version | v13 (was v12; the bump came from the auto-apply above) |
| Snapshots | v15 `pre-telegram-add-v2`, v14 `pre-telegram` |
| `~/.hermes/.env` | TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USERS present (not yet renamed to TELEGRAM_ALLOWED_IDS) |
| Committed to repo | `00ddfb6` (redactions + banners — **not pushed**) |

Side effect noted: policy v13 load introduced a burst of OPA WARN lines
("Cannot access container filesystem for symlink resolution"). Harmless per
the warning itself ("falls back to literal path matching"), but new log noise.

---

## Root cause

From `~/gandalf-bringup/nemoclaw-src/src/lib/actions/sandbox/rebuild.ts:295-392`
the preflight is:

```
session = loadSession()
rebuildCredentialEnv = session.credentialEnv  # if session matches sandbox
# Legacy migration ONLY clears credentialEnv when:
if (session.provider in ("ollama-local", "vllm-local")
    AND rebuildCredentialEnv == "OPENAI_API_KEY"):
   rebuildCredentialEnv = null
# Else require process.env[rebuildCredentialEnv] to be present, or bail.
```

Inspecting `~/.nemoclaw/onboard-session.json` for this sandbox:

```
"provider": "vllm-local",
"credentialEnv": "COMPATIBLE_ANTHROPIC_API_KEY"
```

That's a **state-mismatch**: the provider is `vllm-local` (which is "legacy"
according to the comment), but the credentialEnv field carries the value used
for the Compatible-Anthropic provider path. The migration branch is written
narrowly enough to only handle the `OPENAI_API_KEY` variant; the
`COMPATIBLE_ANTHROPIC_API_KEY` variant slips through into the strict check.

How it got that way is probably a side-effect of an earlier credential rotation
or `set-inference.sh` run that updated the credential env in the session
without correspondingly clearing the provider name. Worth digging into the
runlog if we want a clean fix; the upstream `legacyMigration` branch likely
needs to be widened to cover the `COMPATIBLE_*` variants too, and would be a
sensible upstream PR.

**Important implication:** this isn't a Telegram-specific issue. **Any**
future rebuild (e.g. an upstream Hermes version bump, any subsequent
`channels add`, even a `channels remove` rollback that triggers a rebuild)
hits the same wall until the session is reconciled.

---

## Where are tokens kept?

Tokens live **outside the repo** by design:

- **`~/.hermes/.env`** (on the Spark host, mode `600`, owner `catlett`):
  - `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`,
    `SLACK_HOME_CHANNEL`, `SLACK_ALLOWED_CHANNELS`
  - `HERMES_SUPPRESS_SETHOME_NOTICE`
  - `TAVILY_API_KEY`
  - `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`

- **`~/.config/gogcli/`** (on the Spark host): Google OAuth keyring state.

- **`~/gandalf-bringup/google_token.json`** + `client_secret.json`: host
  backups of the Google OAuth client + access tokens.

- **NemoClaw OpenShell credential store**: tokens registered with
  `nemohermes gandalf channels add <x>` are pushed to the OpenShell gateway
  as host-side providers (visible at runtime as
  `openshell:resolve:env:vNNN_<KEY>` placeholders in the sandbox process env).
  The sandbox **never sees raw token values**; OpenShell's L7 proxy resolves
  the placeholder at the network boundary.

The **repo** carries only the templates (`bringup/secrets.example.env`,
`bringup/config.example.yaml`) with placeholder values. `.gitignore` blocks
`.env`, `*.env`, `*token*.json`, `*client_secret*.json` — so an accidental
`git add` of a real secrets file silently fails. The templates are explicitly
unblocked.

The earlier session committed the live bot token and Tavily key into
`implementation.md`. That's been redacted in commit `00ddfb6` (local; not yet
pushed). **Both tokens have been published to GitHub and need to be rotated**
once Phase B verifies — that's already on the operator's punch list.

---

## Open questions for the operator

### Q1 — Which unblock path? (the gating decision)

| # | Option | Pro | Risk |
|---|---|---|---|
| 1 | Set `COMPATIBLE_ANTHROPIC_API_KEY` to a dummy/placeholder for this rebuild | Cheapest. LiteLLM→argo-shim uses `api_key: dummy-not-used-by-argo`; the runtime never validates this key. | Inference; if NemoClaw's bake step probes the key against an Anthropic endpoint, a dummy fails. Unknown probability. |
| 2 | `nemohermes onboard` interactively | Official path the error message itself recommends. | Big workflow; may re-prompt for many things including Slack creds. Several minutes of investigation to confirm scope. |
| 3 | Hand-edit `~/.nemoclaw/onboard-session.json` to set `credentialEnv: null` (mirroring the upstream legacy-migration branch but for the `COMPATIBLE_ANTHROPIC` variant) | Surgical, reversible, directly justified by the upstream source's own logic. | Hand-edit of a state file — wants a backup first and a check that no other code paths consume `credentialEnv` after preflight. |
| 4 | Roll back: `nemohermes gandalf channels remove telegram` | Minimum surface area; reverts registry/preset/egress to pre-Phase-B. | `channels remove` also triggers a rebuild → hits the same preflight wall. Would need snapshot restore (v15) instead. |

**Operator pick: ___**

### Q2 — Token rotation timing

Plan was: rotate bot token in BotFather + Tavily key in their dashboard
*after* Telegram is verified working. With Phase B blocked, do we:
- **(a)** rotate now anyway (both have been committed and pushed) and re-pre-seed
  the new values before retrying; or
- **(b)** keep the current tokens until verification, then rotate as planned?

Option (a) is safer but invalidates any in-flight provisioning state that
references the old tokens (registry stored a credential hash of the current
token — needs to be re-acquired on rotation).

### Q3 — The `TELEGRAM_ALLOWED_USERS` vs `TELEGRAM_ALLOWED_IDS` mismatch

The bringup README template + your `~/.hermes/.env` use
`TELEGRAM_ALLOWED_USERS`; the upstream NemoClaw source reads
`TELEGRAM_ALLOWED_IDS`. I shimmed it inline for this run by also exporting
the `_IDS` variant. Long-term, do you want:
- **(a)** rename the env line in `~/.hermes/.env` (and template + README) to
  `TELEGRAM_ALLOWED_IDS`; or
- **(b)** keep both lines for belt-and-suspenders (some Hermes paths might
  still expect `_USERS`)?

I haven't grepped for the legacy `_USERS` form in Hermes itself; will do
that before the README rewrite if you want recommendation (b) ruled out.

### Q4 — Session reconciliation as a separate task?

The `onboard-session.json` mismatch is a pre-existing condition that will
keep biting future rebuilds. Should we:
- **(a)** roll a follow-up runlog entry + filed-issue for this (so a future
  upstream PR widens the legacy-migration branch); or
- **(b)** leave it as an undocumented Spark-specific quirk and just remember
  to set `COMPATIBLE_ANTHROPIC_API_KEY=<dummy>` before every rebuild?

### Q5 — README rewrite scope (deferred until green)

Once Telegram comes up, do you want the README rewrite to:
- **(a)** cover only Telegram (mirror the corrected mechanism we now
  understand); or
- **(b)** generalize to a "how to add a new messaging channel" runbook that
  any future channel (Discord, etc.) can follow?

Option (b) is the more durable artifact but takes longer.

### Q6 — Snapshot retention

We now have v14 + v15 + 13 older snapshots in
`~/.nemoclaw/rebuild-backups/gandalf/`. After Phase B completes (whenever
that is), keep all or prune? Recommend keep at least v3 `phase-h-baseline`,
v10 `pre-slack-home-fix`, v14 `pre-telegram`, plus one new "telegram-live"
once we're green.

---

## Recommended next step

I lean toward **Q1 option 3** (hand-edit `onboard-session.json` — the
surgical fix consistent with the upstream's own migration logic). It's the
only one that's both cheap AND doesn't pollute future operations. But because
you specifically said "anything unexpected → stop and report" and you're
offline, I'd rather not pick on my own.

If you want the most conservative single move while you're offline,
**Q1 option 4 + snapshot restore v15** (full rollback to start of Phase B) is
the cleanest holding pattern — but the underlying credential-env mismatch will
still need to be addressed before any rebuild can happen.

---

## Untouched (waiting on Q1)

- `bash ops/post-rebuild.sh` (only runs after a successful rebuild).
- Smoke gates: 3 platforms connected, TLS to api.telegram.org, Slack
  regression check.
- README Part B rewrite.
- BotFather token rotation + Tavily key rotation.

---

## Files of interest

- This file: `bringup/70-telegram/phase-b-blocked.md`
- Predecessor (still authoritative on mechanism): `bringup/70-telegram/phase-a-findings.md`
- Channels-add log (the partial success): `/tmp/channels-add-telegram.log`
  (host-side, not in repo)
- Live session state: `~/.nemoclaw/onboard-session.json`
- Local-only commit awaiting push: `00ddfb6` (redactions + banners)
