# Telegram Phase B — external review response + how to proceed

**Author:** external review (Opus, on the operator's MacBook), 2026-06-27.
**Reviewed:** `phase-b-blocked.md` + `status-for-external-review.md` + `phase-a-findings.md`.
**For:** Claude Code on the Spark.

This message constitutes the operator's confirmation, per the CLAUDE.md
destructive-ops policy, to (a) hand-edit `~/.nemoclaw/onboard-session.json`
(with a backup) and (b) perform the sandbox rebuild — **provided** the
read-only pre-checks in step 1 pass. Snapshot **v15 `pre-telegram-add-v2`** is
the rollback. If any gate or stop-condition below trips, restore v15 and report;
do not improvise.

---

## Verdict on the report

- Diagnosis is correct and well-evidenced. The `provider: vllm-local` +
  `credentialEnv: COMPATIBLE_ANTHROPIC_API_KEY` mismatch in
  `onboard-session.json`, slipping past a legacy-migration branch written only
  for the `OPENAI_API_KEY` variant, fully explains the preflight bail.
- Stopping before the rebuild was right; the sandbox is intact and Slack is
  still live. Good.
- **Decision (Q1): Option 3** — reconcile the session — with Option 1 (dummy
  key) as fallback and Option 4 (snapshot-restore v15) as the abort path. Reason:
  Option 3 is the only choice that also clears the latent mismatch that would
  otherwise block *every* future rebuild (Q4), and it's directly justified by
  the upstream's own migration logic.

## Two risks the in-session analysis under-weighted — handle these

### R1 — The registered Telegram token is probably the REVOKED one
`channels add` acquired `TELEGRAM_BOT_TOKEN` from `process.env` **before** the
rotation. So the OpenShell credential provider almost certainly holds the old,
now-revoked token. If you rebuild without re-provisioning, the adapter will
authenticate with a dead token and fail (Telegram `401`), which can look like a
different bug. **Before rebuilding:** confirm whether the credential is acquired
at `channels add` time (stale) or re-read from `process.env` at rebuild time
(fresh). Either way, ensure the **new** token is what gets provisioned —
re-source the updated `~/.hermes/.env` so the new `TELEGRAM_BOT_TOKEN` is in the
environment, and re-run whatever step re-acquires the channel credential into
the OpenShell store. Verify the stored credential reflects the new token, not
the old one.

### R2 — The allowlist must actually reach the adapter (security gate)
Phase A showed the allowlist flows via `NEMOCLAW_MESSAGING_ALLOWED_IDS_B64`
(for Slack: `{"slack":["U05H8JM8NFQ"]}`). NemoClaw populates that from
`TELEGRAM_ALLOWED_IDS` (the key the upstream actually reads), not the
`TELEGRAM_ALLOWED_USERS` in the current `.env`/template. So: export
`TELEGRAM_ALLOWED_IDS` (= the operator's numeric Telegram ID) for the rebuild,
and after the rebuild **verify `NEMOCLAW_MESSAGING_ALLOWED_IDS_B64` decodes to
`{"telegram":["<that-one-id>"], ...}`**. An empty or wildcard telegram allowlist
= a dead-or-open bot; treat that as a failure.

---

## Answers to the open questions

- **Q1 (unblock path):** Option 3 (below), Option 1 fallback, Option 4 abort.
- **Q2 (rotation timing):** Already done — both keys are rotated and installed.
  Moot, except for R1 (make sure the rebuild provisions the new token).
- **Q3 (`_USERS` vs `_IDS`):** Use `TELEGRAM_ALLOWED_IDS` — it's what NemoClaw
  reads to build the allowlist. Quick-grep Hermes itself for a legacy `_USERS`
  consumer; if one exists, keep both lines, otherwise rename. Fold into the
  README/template fix once green. The R2 verification is what actually proves
  the right key was used.
- **Q4 (session reconciliation):** Yes — Option 3 *is* the reconciliation. Add a
  short `runlog/` entry documenting the mismatch + fix, and note the upstream PR
  opportunity (widen the legacy-migration branch to cover `COMPATIBLE_*_API_KEY`
  paired with `vllm-local`/`ollama-local`).
- **Q5 (README rewrite):** Deferred until green. Telegram-specific first
  (accurate, fast); a generalized "add a messaging channel" runbook can be a
  later FOLLOWUPS item.
- **Q6 (snapshots):** Defer pruning. Keep at least v3 `phase-h-baseline`,
  v14 `pre-telegram`, v15 `pre-telegram-add-v2`, and a new `telegram-live` once
  green.

---

## Execution plan

### Step 1 — Read-only pre-checks (no state change). STOP if any fail.
1. **Backup** `~/.nemoclaw/onboard-session.json` to a timestamped copy.
2. **Grep the upstream** (`~/gandalf-bringup/nemoclaw-src`) for *all* reads of
   `credentialEnv` / `onboard-session`, not just `rebuild.ts`. Confirm the only
   consumer that matters after a `vllm-local` preflight is the preflight itself
   — i.e. setting it null/realigned won't strip the rebuilt sandbox's inference
   credential. If a downstream consumer would break, **stop** and switch to
   Option 1 (dummy key) instead.
3. **Confirm inference doesn't depend on the session field:** the live sandbox
   runs inference fine right now while `COMPATIBLE_ANTHROPIC_API_KEY` is absent
   from the env — so the field is already inert at runtime. Confirm the live
   `/sandbox/.hermes/config.yaml` inference block points at vLLM
   (`OPENAI_API_KEY`=local, `host.openshell.internal:8000`); that, not the
   session field, is what feeds inference after a rebuild.
4. **R1 check:** determine whether the stored Telegram credential is the old
   (pre-rotation) token.

### Step 2 — Reconcile the session (Option 3)
Edit `~/.nemoclaw/onboard-session.json` so a `vllm-local` provider no longer
demands a cloud key. Set `credentialEnv` to the value that makes the upstream
legacy-migration fire cleanly for `vllm-local` — i.e. `"OPENAI_API_KEY"` (the
provider's real credential env, which the migration then nulls automatically),
or directly `null`. Pick based on the source you read in step 1; justify the
choice in the runlog. Keep the backup.

### Step 3 — Provision the NEW token + correct allowlist (R1 + R2)
Re-source the updated `~/.hermes/.env`; ensure the environment carries the new
`TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_IDS=<operator numeric id>` (plus
`TELEGRAM_REQUIRE_MENTION=0` for DM-only). Re-acquire the channel credential so
the OpenShell store holds the new token.

### Step 4 — Rebuild
Trigger the rebuild (the bridge is already registered). Confirm the preflight
now passes. Then run `bash ops/post-rebuild.sh` and watch each step — flag any
error instead of pushing past it (it hasn't been exercised since the Tavily
pivot).

### Step 5 — Smoke gates (strict; fail-loud). Restore v15 on any failure.
1. `gateway.log`: `✓ api_server connected`, `✓ slack connected`,
   `✓ telegram connected`, `Gateway running with 3 platform(s)`.
2. **Inference round-trip works** (vLLM via LiteLLM) — proves the session edit
   didn't break inference.
3. **Allowlist correct:** `NEMOCLAW_MESSAGING_ALLOWED_IDS_B64` decodes to a
   telegram entry containing only the operator's ID (R2).
4. Outbound TLS to `api.telegram.org` within ~30s of the gateway coming up.
5. **Slack not regressed** — still connected and DM-able.

### Step 6 — Hold for operator DM confirmation
The operator is in transit and can't do the live DM round-trip yet. Take it
through the gates above, then **report status as "provisioned + gateway-verified,
pending operator DM round-trip"** — do not mark fully verified until the operator
confirms a real DM both ways.

---

## Stop-and-report / rollback triggers
- Preflight fails again after the session edit → restore v15, report.
- Inference round-trip fails post-rebuild → restore v15, report.
- Slack drops, or the telegram allowlist is empty/wildcard → restore v15, report.
- `post-rebuild.sh` errors on any step → stop, report (don't push past).
- Anything else unexpected → stop, report. Do not improvise a second fix.

## Commit / push
Commit `phase-b-blocked.md`, `status-for-external-review.md`, this file, the
new session-reconciliation runlog entry, and (after green) the `_IDS`
fix to the template/README. **Leave the push to the operator.** Put no token in
any tracked file.
