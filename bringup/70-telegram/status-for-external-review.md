# Telegram bring-up — status for external review

**Date:** 2026-06-27
**Repo:** github.com/cecat/Spark-Hermes (this commit is the head of `main`)
**Operator:** catlett, currently offline (in transit)
**Author:** Claude Code (Opus 4.7) session running on the Spark host

This file is a single self-contained snapshot for an external model to review.
Reading it doesn't require any other file in the repo, but supporting context
lives in:

- [`CLAUDE.md`](../../CLAUDE.md) — repo conventions + destructive-ops policy (not in git; lives on operator's Spark)
- [`README.md`](README.md) — Telegram bring-up README (Part A human / Part B Claude Code), the original plan we tried to execute
- [`implementation.md`](implementation.md) — first-pass log from earlier today; **superseded** (header banner explains)
- [`NEXT-STEPS-FOR-CLAUDE-CODE.md`](NEXT-STEPS-FOR-CLAUDE-CODE.md) — corrective plan written from the Mac after reading runlogs; **also superseded** (header banner explains)
- [`phase-a-findings.md`](phase-a-findings.md) — Phase A diagnosis (read-only) that overturned the NEXT-STEPS premise
- [`phase-b-blocked.md`](phase-b-blocked.md) — Phase B execution log; where we got stuck

Background on the stack itself is in the repo's top-level
[`README.md`](../../README.md) and the upstream sources we've been reading at
`~/gandalf-bringup/nemoclaw-src/` (not in this repo).

---

## What we're trying to do

Add a **second, inbound, conversational** messaging adapter to **Gandalf** (a
personal-assistant Hermes Agent running in an NVIDIA OpenShell sandbox managed
by NemoClaw, with local vLLM Qwen inference + remote Argonne Claude via
LiteLLM). Slack inbound works today. Want Telegram alongside Slack so the
operator can DM the bot from a phone without needing the Slack app — bot
replies via the same Telegram chat. Outbound-only cron delivery to Telegram is
explicitly **not** wanted; the daily briefing stays on Slack.

Versions in play:
- NemoHermes `v0.1.0`, OpenShell `0.0.44`, Hermes Agent `v2026.5.16`
- Sandbox is currently up (phase `Ready`), Slack adapter live and DM-able

---

## Where we are now (one screen)

### Done

1. **Secrets-hygiene fix.** Earlier docs in this directory had the live
   Telegram bot token + Tavily API key committed in plaintext (mistake). All
   redacted to placeholders (`<BOT_TOKEN>` / `<TAVILY_KEY>` /
   `<ALLOWED_USER_ID>`). Operator has since **rotated both keys**; new values
   installed in:
   - `~/.hermes/.env` (host, mode 600)
   - `/sandbox/.hermes/.env` (in-container)
   - `/etc/nemoclaw/hermes.config-hash` (recomputed sha256)
   Neither real value is in the repo.

2. **Two pre-Phase-B snapshots** captured for rollback: v14 `pre-telegram`,
   v15 `pre-telegram-add-v2` (in `~/.nemoclaw/rebuild-backups/gandalf/`).

3. **OpenShell egress** opened for `api.telegram.org` (built-in `telegram`
   preset auto-applied by `channels add` + custom `telegram-egress` preset
   from the repo).

4. **`nemohermes gandalf channels add telegram` ran successfully through
   gateway-side provisioning**:
   ```
   ✓ Registered telegram bridge with the OpenShell gateway.
   Widening sandbox egress — adding: api.telegram.org
   ✓ Policy version 13 submitted (hash: a6a537c8d6b7)
   ✓ Policy version 13 loaded (active version: 13)
   Applied preset: telegram
   ```
   The registry (`~/.nemoclaw/sandboxes.json`) now lists
   `messagingChannels: ["slack", "telegram"]`. Token was passed via
   `process.env` pre-seed (NemoClaw's `getCredential()` reads process env
   directly).

### Blocked

5. **The rebuild aborted at preflight**, before destroying anything:
   ```
   Rebuild preflight failed: provider credential not found.
   The non-interactive recreate step requires COMPATIBLE_ANTHROPIC_API_KEY,
   but it is not set in the environment.

   Sandbox is untouched — no data was lost.
   ```

### Live state right now

- Sandbox phase: `Ready` (untouched). Gateway PID 197 still running.
- **Slack adapter still connected** — gateway never restarted, NemoClaw env
  unchanged. Real Slack DMs would still round-trip.
- **Telegram adapter NOT running** — the in-sandbox image hasn't been rebuilt
  to know about it yet, so even though the bridge is registered with OpenShell
  and egress is open, no process is long-polling api.telegram.org.
- Live `/sandbox/.hermes/.env` contains the **new** rotated Telegram token and
  Tavily key; gateway PID 197's process env still holds the **old** Tavily key
  (it was never restarted after the rotation). The new values activate on
  next gateway cycle.
- Phase B work committed and pushed; this status doc and the unblock are
  what's left.

---

## Root cause of the block

From `~/gandalf-bringup/nemoclaw-src/src/lib/actions/sandbox/rebuild.ts:295-392`:

```typescript
const session = onboardSession.loadSession();        // ~/.nemoclaw/onboard-session.json
let rebuildCredentialEnv = session?.credentialEnv;   // "COMPATIBLE_ANTHROPIC_API_KEY"

// Legacy migration: only clears credentialEnv when it equals OPENAI_API_KEY,
// not COMPATIBLE_ANTHROPIC_API_KEY or any other compatible-* variant.
if ((session?.provider === "ollama-local" || session?.provider === "vllm-local")
    && rebuildCredentialEnv === "OPENAI_API_KEY") {
    rebuildCredentialEnv = null;
}

if (rebuildCredentialEnv) {
    const credentialValue = hydrateCredentialEnv(rebuildCredentialEnv);
    if (!credentialValue) {
        console.error("Rebuild preflight failed: provider credential not found.");
        bail(`Missing credential: ${rebuildCredentialEnv}`);
    }
}
```

The actual recorded `~/.nemoclaw/onboard-session.json` for this sandbox:

```json
{
  "sandboxName": "gandalf",
  "provider": "vllm-local",
  "credentialEnv": "COMPATIBLE_ANTHROPIC_API_KEY",
  ...
}
```

That's a **state mismatch**: `provider: vllm-local` (the legacy local-inference
provider this Spark uses) is paired with `credentialEnv:
COMPATIBLE_ANTHROPIC_API_KEY` (the env key for the "Other Anthropic-compatible
endpoint" provider). The legacy-migration shortcut is hand-written for the
`OPENAI_API_KEY` variant only, so the `COMPATIBLE_ANTHROPIC_API_KEY` variant
slips through.

How it got that way is unclear from the runlog. Plausible: a previous
`set-inference.sh` run, or an earlier `nemohermes onboard` re-run that
updated `credentialEnv` without also touching `provider`. The actual runtime
inference path is **vLLM Qwen → LiteLLM `127.0.0.1:4000` → if model name
matches `claude*`, route via argo-shim's SSH tunnel to Argonne**; the
LiteLLM config carries `api_key: dummy-not-used-by-argo` for the Claude
routes. No real Anthropic API key is needed at runtime; argo-shim
authenticates via the SSH tunnel.

**Important:** this isn't Telegram-specific. **Any** future rebuild —
upstream Hermes version bump, another `channels add`, even a `channels
remove` to roll back — hits the same wall until this is reconciled.

---

## The four unblock options (this is the gating decision)

| # | Option | Pro | Risk |
|---|---|---|---|
| **1** | Set `COMPATIBLE_ANTHROPIC_API_KEY` to a dummy/placeholder for this rebuild only (e.g. `export COMPATIBLE_ANTHROPIC_API_KEY="sk-ant-dummy-litellm-routes-to-argo-not-anthropic"`). | Cheapest. Runtime path is LiteLLM→argo-shim which uses a dummy already (`api_key: dummy-not-used-by-argo` in `litellm/config.yaml`); the runtime never validates this key. | Inference: if NemoClaw's bake step *probes* the key against an Anthropic endpoint during image build, a dummy fails. We don't know whether it does — would need to read more of the bake path to be sure. Sandbox is still safe-by-design ("untouched, no data lost") if it does fail at preflight again. |
| **2** | `nemohermes onboard` interactively. | Official path the error message itself recommends ("re-enter the key interactively"). | Larger workflow than just credential reset; could re-prompt for many things (provider choice, Slack creds, etc.). Several minutes of upstream source-reading to know scope. May or may not actually fix the state-mismatch — depends on whether onboard rewrites the session to a clean state or just patches the credential. |
| **3** | Hand-edit `~/.nemoclaw/onboard-session.json` to set `credentialEnv: null` (mirroring the upstream legacy-migration branch but for the `COMPATIBLE_ANTHROPIC` variant instead of `OPENAI_API_KEY`). | Surgical, reversible (back up the JSON first), directly justified by the upstream source's own migration logic — we're just extending the rule one variant wider. Doesn't pollute future operations. | Hand-editing a state file. Want to grep upstream first to confirm nothing else downstream reads `credentialEnv` after preflight (e.g. the bake step itself, or a healthcheck after rebuild). |
| **4** | Roll back: `nemohermes gandalf channels remove telegram`, accept that Telegram is deferred until the credential-env mismatch is fixed separately. | Minimum surface area; reverts registry/preset/egress to pre-Phase-B state. | `channels remove` *also* triggers a rebuild → hits the same preflight wall. Would have to instead `snapshot restore pre-telegram-add-v2` (v15) which bypasses the rebuild but takes Slack down briefly during the restore. The underlying credential-env mismatch is unaddressed; will keep biting any future rebuild. |

Claude Code's recommendation (with the caveat that the operator said "stop and
report on anything unexpected"): **Option 3 first** (surgical fix consistent
with upstream logic), with Option 4 (rollback via snapshot) as the safe holding
pattern if Option 3 doesn't pan out. Option 1 is appealing if Option 3 is
ruled out by downstream-consumer concerns about `credentialEnv: null`.

---

## What we'd like external advice on

1. **Which of options 1–4 would you pick, and why?** Particularly interested
   in tradeoffs the in-session analysis might be missing.

2. **For Option 3 (the hand-edit):** is there a downstream consumer of
   `session.credentialEnv` after the rebuild preflight passes that we
   should check first? We've grepped `rebuild.ts` and the preflight is the
   only consumer in that file, but the codebase is large.

3. **For Option 1 (the dummy key):** does NemoClaw's image-bake step
   actually validate the key against an Anthropic endpoint, or is it just
   passed through to the runtime where it's never used? We *think* the
   latter (because LiteLLM is the actual endpoint and it's already
   configured with a dummy), but haven't traced the bake path end-to-end.

4. **Is there a cleaner upstream fix worth proposing as a PR?** The
   legacy-migration branch at `rebuild.ts:334-345` is hand-written for
   the `OPENAI_API_KEY` variant — extending it to cover any
   `COMPATIBLE_*_API_KEY` paired with `vllm-local` or `ollama-local`
   would prevent this class of state-mismatch from biting other deployments.

5. **Anything else surprising in the Phase A finding** (that Slack inbound
   runs from NemoClaw env-injection at the gateway boundary, not from a
   `platforms.slack` block in `config.yaml`)? Want a sanity check that we
   haven't misread the gateway env or the upstream `nemoclaw` plugin
   activation code.

---

## State-of-disk for the reviewer

```
$ git status
On branch main
nothing to commit, working tree clean

$ git log --oneline -10
<this commit>  70-telegram: status-for-external-review.md
c8abd82  70-telegram: redact secrets from tracked docs; add superseded banners (push earlier)
00ddfb6  (local-only) 70-telegram: redact secrets from tracked docs; add superseded banners
510e13b  70-telegram: Phase A read-only findings — Slack inbound runs via NemoClaw env
04960b3  70-telegram: phase-a-findings.md
bf8b3c7  70-telegram: implementation log + flag README gap (rebuild required)
3ecbdbf  70-telegram: restructure README into human Part A + Claude Code Part B handoff
bc30536  Add Telegram adapter phase (augments Slack)
...
```

(Order may differ slightly when you read this; the relevant docs are the five
in `bringup/70-telegram/`.)

Live snapshots:
```
v15  pre-telegram-add-v2   2026-06-27T13-03-11-679Z
v14  pre-telegram          2026-06-27T11-44-21-092Z
```

Live OpenShell policy version: **v13** (was v12 before the Telegram
auto-apply); `telegram-egress` + built-in `telegram` both active.

---

## What I (Claude Code) will NOT do until told

- Touch the sandbox in any way (no rebuild, no recover, no channels add/remove,
  no snapshot restore).
- Edit `~/.nemoclaw/onboard-session.json`.
- Cycle the gateway.
- Push to GitHub anything past this status doc.

Waiting on operator decision (which is waiting on external review).
